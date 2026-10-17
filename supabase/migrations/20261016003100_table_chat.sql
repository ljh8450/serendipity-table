-- CHAT-001: real persisted chat; current assignments are always authoritative.
create table app_private.chat_rooms (
 id uuid primary key default gen_random_uuid(),table_id uuid not null unique references app_private.dining_tables(id) on delete cascade,
 status text not null default 'OPEN' check(status in ('OPEN','CLOSED')),created_at timestamptz not null default clock_timestamp()
);
create table app_private.chat_members (
 id uuid primary key default gen_random_uuid(),room_id uuid not null references app_private.chat_rooms(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,participant_no int not null check(participant_no>0),
 active boolean not null default true,unique(room_id,user_id),unique(room_id,participant_no),unique(room_id,id)
);
create table app_private.chat_messages (
 id bigint generated always as identity primary key,room_id uuid not null references app_private.chat_rooms(id) on delete cascade,
 member_id uuid,request_key uuid,system_key text,kind text not null check(kind in ('MEMBER','SYSTEM')),
 body text not null check(length(body) between 1 and 1000 and length(btrim(body))>0),created_at timestamptz not null default clock_timestamp(),
 foreign key(room_id,member_id) references app_private.chat_members(room_id,id) on delete cascade,
 check((kind='MEMBER' and member_id is not null and request_key is not null and system_key is null) or (kind='SYSTEM' and member_id is null and request_key is null and system_key is not null)),
 unique(room_id,member_id,request_key),unique(room_id,system_key)
);
create index chat_room_page on app_private.chat_messages(room_id,id desc);
create index chat_sender_rate on app_private.chat_messages(member_id,created_at desc);
create table app_private.chat_receipts (
 event_id uuid primary key references app_private.match_outbox(id) on delete cascade,
 status text not null default 'QUEUED' check(status in ('QUEUED','DONE','EXCEPTION')),
 attempts int not null default 0,due_at timestamptz not null default clock_timestamp(),last_error text,finished_at timestamptz
);
do $$ declare n text;begin
 foreach n in array array['chat_rooms','chat_members','chat_messages','chat_receipts'] loop
 execute format('alter table app_private.%I enable row level security',n);
 execute format('revoke all on app_private.%I from public,anon,authenticated,app_member_api',n);end loop;
end $$;

create function app_private.chat_apply(table_uuid uuid,event_uuid uuid,event_kind text) returns void
language plpgsql security definer set search_path='' as $$
declare t app_private.dining_tables%rowtype;r app_private.chat_rooms%rowtype;u uuid;number int;
begin
 select * into t from app_private.dining_tables where id=table_uuid for update;
 if t.id is null or t.status<>'CONFIRMED' then
  update app_private.chat_rooms set status='CLOSED' where table_id=table_uuid returning * into r;
  update app_private.chat_members set active=false where room_id=r.id;return;
 end if;
 if (select count(*) from app_private.table_assignments where table_id=t.id and active) not between 4 and 6 then raise exception 'CHAT_INVALID_TABLE';end if;
 insert into app_private.chat_rooms(table_id) values(t.id) on conflict(table_id) do nothing;
 select * into r from app_private.chat_rooms where table_id=t.id for update;
 if r.status<>'OPEN' then raise exception 'CHAT_CLOSED_TABLE';end if;
 update app_private.chat_members m set active=false where m.room_id=r.id and not exists(select 1 from app_private.table_assignments ta where ta.table_id=t.id and ta.user_id=m.user_id and ta.active);
 for u in select user_id from app_private.table_assignments where table_id=t.id and active order by id loop
  select coalesce(max(participant_no),0)+1 into number from app_private.chat_members where room_id=r.id;
  insert into app_private.chat_members(room_id,user_id,participant_no) values(r.id,u,number) on conflict(room_id,user_id) do nothing;
 end loop;
 insert into app_private.chat_messages(room_id,kind,system_key,body) values(r.id,'SYSTEM','welcome','식탁 단체방이 열렸어요. 장소와 준비 안내는 매칭 상태에서 확인해 주세요.') on conflict(room_id,system_key) do nothing;
 if event_kind='TABLE_UPDATED' then
  insert into app_private.chat_messages(room_id,kind,system_key,body) values(r.id,'SYSTEM','event:'||event_uuid,'참가 구성이 변경됐어요. 최신 매칭 상태를 확인해 주세요.') on conflict(room_id,system_key) do nothing;
 end if;
end $$;
create function app_private.chat_tick() returns int
language plpgsql security definer set search_path='' as $$
declare event record;code text;processed int:=0;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('chat-tick',0)) then return 0;end if;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 insert into app_private.chat_receipts(event_id) select id from app_private.match_outbox where event_type in ('TABLE_CONFIRMED','TABLE_UPDATED','TABLE_INVALIDATED') on conflict do nothing;
 for event in select r.event_id,o.aggregate_id,o.event_type from app_private.chat_receipts r join app_private.match_outbox o on o.id=r.event_id where r.status='QUEUED' and r.due_at<=clock_timestamp() order by o.created_at,o.id for update of r skip locked limit 20 loop
  begin
   perform app_private.chat_apply(event.aggregate_id,event.event_id,event.event_type);
   update app_private.chat_receipts set status='DONE',attempts=attempts+1,last_error=null,finished_at=clock_timestamp() where event_id=event.event_id;
  exception when others then
   code:=case when sqlerrm in ('CHAT_INVALID_TABLE','CHAT_CLOSED_TABLE') then sqlerrm else 'CHAT_EXECUTION_FAILED' end;
   update app_private.chat_receipts set attempts=attempts+1,status=case when attempts>=2 then 'EXCEPTION' else 'QUEUED' end,last_error=code,due_at=clock_timestamp()+interval '1 minute' where event_id=event.event_id;
  end;
  processed:=processed+1;
 end loop;return processed;
end $$;
select cron.schedule('serendipity-chat-tick','* * * * *','select app_private.chat_tick();');

-- Invoked inside a matching-state transaction fence for linearized authorization.
create function app_private.chat_authorize(room_uuid uuid,actor_uuid uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare member_uuid uuid;
begin
 select m.id into member_uuid from app_private.chat_members m join app_private.chat_rooms r on r.id=m.room_id
 join app_private.dining_tables t on t.id=r.table_id
 where r.id=room_uuid and r.status='OPEN' and t.status='CONFIRMED' and m.user_id=actor_uuid and m.active
 and exists(select 1 from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id
  where ta.table_id=t.id and ta.user_id=actor_uuid and ta.active and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED');
 if member_uuid is null then raise exception 'FORBIDDEN';end if;
 return member_uuid;
end $$;
create function app_private.chat_get(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();room_uuid uuid;member_uuid uuid;before_id bigint;page jsonb;has_older boolean;next_before text;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['roomId','before'] or (select count(*) from jsonb_object_keys(payload))<>2
 or coalesce(payload->>'roomId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or not(payload->'before'='null'::jsonb or (jsonb_typeof(payload->'before')='string' and payload->>'before' ~ '^[1-9][0-9]{0,18}$')) then raise exception 'VALIDATION_ERROR';end if;
 begin before_id:=(payload->>'before')::bigint;exception when numeric_value_out_of_range then raise exception 'VALIDATION_ERROR';end;
 room_uuid:=(payload->>'roomId')::uuid;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 member_uuid:=app_private.chat_authorize(room_uuid,actor);
 select count(*)>50 into has_older from (select id from app_private.chat_messages where room_id=room_uuid and (before_id is null or id<before_id) order by id desc limit 51) p;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id::text,'kind',p.kind,'body',p.body,'sentAt',p.created_at,'mine',p.member_id=member_uuid,
  'sender',case when p.kind='SYSTEM' then '시스템' else '참가자 '||m.participant_no end) order by p.id),'[]'::jsonb),min(p.id)::text into page,next_before
 from (select * from app_private.chat_messages where room_id=room_uuid and (before_id is null or id<before_id) order by id desc limit 50) p left join app_private.chat_members m on m.id=p.member_id;
 return jsonb_build_object('roomId',room_uuid,'messages',page,'nextBefore',case when has_older then next_before else null end,
  'members',(select jsonb_agg(jsonb_build_object('label','참가자 '||m.participant_no,'mine',m.id=member_uuid) order by m.participant_no) from app_private.chat_members m join app_private.chat_rooms r on r.id=m.room_id where m.room_id=room_uuid and m.active and exists(select 1 from app_private.table_assignments ta where ta.table_id=r.table_id and ta.user_id=m.user_id and ta.active)));
end $$;
create function app_private.chat_send(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();room_uuid uuid;member_uuid uuid;k uuid;old app_private.chat_messages%rowtype;msg_id bigint;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['roomId','requestKey','body'] or (select count(*) from jsonb_object_keys(payload))<>3
 or coalesce(payload->>'roomId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or jsonb_typeof(payload->'body') is distinct from 'string' or length(payload->>'body') not between 1 and 1000 or length(btrim(payload->>'body'))=0 then raise exception 'VALIDATION_ERROR';end if;
 room_uuid:=(payload->>'roomId')::uuid;k:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 member_uuid:=app_private.chat_authorize(room_uuid,actor);
 select * into old from app_private.chat_messages where room_id=room_uuid and member_id=member_uuid and request_key=k;
 if old.id is not null then
  if old.body<>payload->>'body' then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  return jsonb_build_object('messageId',old.id::text);
 end if;
 if (select count(*) from app_private.chat_messages where member_id=member_uuid and created_at>clock_timestamp()-interval '60 seconds')>=10 then raise exception 'CHAT_RATE_LIMIT';end if;
 insert into app_private.chat_messages(room_id,member_id,request_key,kind,body) values(room_uuid,member_uuid,k,'MEMBER',payload->>'body') returning id into msg_id;
 insert into app_private.member_audit(actor_id,action) values(actor,'CHAT_MESSAGE_SENT');
 return jsonb_build_object('messageId',msg_id::text);
end $$;

create function app_private.operations_chat_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();
begin
 return jsonb_build_object('rooms',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'status',r.status,'createdAt',r.created_at,'regionLabel',e.region_label,'startsAt',e.starts_at,'memberCount',(select count(*) from app_private.chat_members where room_id=r.id and active),'messageCount',(select count(*) from app_private.chat_messages where room_id=r.id))) from (select * from app_private.chat_rooms order by created_at desc limit 100) r join app_private.dining_tables t on t.id=r.table_id join app_private.intake_event_slots e on e.id=t.slot_id),'[]'::jsonb),
 'exceptions',coalesce((select jsonb_agg(jsonb_build_object('eventId',r.event_id,'code',r.last_error,'status',r.status,'attempts',r.attempts)) from (select * from app_private.chat_receipts where last_error is not null order by due_at desc limit 100) r),'[]'::jsonb));
end $$;
create function app_private.operations_chat_retry(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();changed int;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ? 'eventId' or (select count(*) from jsonb_object_keys(payload))<>1 then raise exception 'VALIDATION_ERROR';end if;
 update app_private.chat_receipts set status='QUEUED',attempts=0,due_at=clock_timestamp(),last_error=null where event_id::text=payload->>'eventId' and status='EXCEPTION';
 get diagnostics changed=row_count;if changed<>1 then raise exception 'JOB_CONFLICT';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'CHAT_EXCEPTION_REQUEUED');return app_private.operations_chat_get();
end $$;
alter function app_private.matching_get() rename to matching_get_v3;
revoke all on function app_private.matching_get_v3() from app_member_api;
create function app_private.matching_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();dto jsonb;
begin
 dto:=app_private.matching_get_v3();
 return jsonb_build_object('applications',coalesce((select jsonb_agg(case when item->'table'='null'::jsonb then item else jsonb_set(item,'{table}',item->'table'||jsonb_build_object('chat',case when r.id is not null then jsonb_build_object('roomId',r.id,'status','READY') else 'null'::jsonb end)) end order by ordinal)
 from jsonb_array_elements(dto->'applications') with ordinality j(item,ordinal)
 left join app_private.table_assignments ta on ta.application_id::text=item->>'id' and ta.user_id=actor and ta.active
 left join app_private.chat_rooms r on r.table_id=ta.table_id and r.status='OPEN'
 and exists(select 1 from app_private.chat_members m where m.room_id=r.id and m.user_id=actor and m.active)),'[]'::jsonb));
end $$;
revoke all on function app_private.chat_apply(uuid,uuid,text),app_private.chat_tick(),app_private.chat_authorize(uuid,uuid),app_private.chat_get(jsonb),app_private.chat_send(jsonb),app_private.operations_chat_get(),app_private.operations_chat_retry(jsonb),app_private.matching_get() from public,anon,authenticated,app_member_api;
grant execute on function app_private.chat_get(jsonb),app_private.chat_send(jsonb),app_private.operations_chat_get(),app_private.operations_chat_retry(jsonb),app_private.matching_get() to app_member_api;
