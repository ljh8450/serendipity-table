-- Private, recipient-scoped notifications. External push is a separate consumer.
create table app_private.member_notifications (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 event_key text not null, kind text not null check(kind in ('TABLE_CONFIRMED','TABLE_UPDATED','TABLE_INVALIDATED','ALTERNATIVE_OFFERED','VENUE_ASSIGNED','CHAT_MESSAGE')),
 table_id uuid references app_private.dining_tables(id) on delete cascade,
 application_id uuid references app_private.intake_applications(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(), read_at timestamptz,
 unique(user_id,event_key)
);
create index on app_private.member_notifications(user_id,created_at desc,id);
alter table app_private.member_notifications enable row level security;
create table app_private.notification_receipts (
 event_id uuid primary key references app_private.match_outbox(id) on delete cascade,
 finished_at timestamptz not null default clock_timestamp()
);
alter table app_private.notification_receipts enable row level security;

create function app_private.notification_visible(n app_private.member_notifications, actor uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select n.user_id=actor and case
 when n.kind in ('ALTERNATIVE_OFFERED','TABLE_INVALIDATED') then exists(
  select 1 from app_private.intake_applications a where a.id=n.application_id and a.user_id=actor and a.application_status='SUBMITTED')
 else exists(select 1 from app_private.table_assignments ta
  join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_applications a on a.id=ta.application_id
  where ta.table_id=n.table_id and ta.user_id=actor and ta.active and t.status='CONFIRMED'
  and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED'
  and (n.kind<>'VENUE_ASSIGNED' or exists(select 1 from app_private.venue_allocations v where v.table_id=t.id and v.active and n.event_key='venue:'||v.id::text))
  and (select count(*) from app_private.table_assignments x where x.table_id=t.id and x.active) between 4 and 6)
 end
$$;
create function app_private.notifications_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); result jsonb; unread bigint;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 select count(*) into unread from app_private.member_notifications n where n.user_id=actor and n.read_at is null and app_private.notification_visible(n,actor);
 select coalesce(jsonb_agg(item order by created_at desc,id desc),'[]'::jsonb) into result from (
  select n.created_at,n.id,jsonb_build_object('id',n.id,'kind',n.kind,'createdAt',n.created_at,'read',n.read_at is not null,
  'title',case n.kind when 'TABLE_CONFIRMED' then '식탁이 확정됐어요' when 'TABLE_UPDATED' then '식탁 안내가 변경됐어요'
   when 'TABLE_INVALIDATED' then '식탁을 다시 준비하고 있어요' when 'ALTERNATIVE_OFFERED' then '다음 참가 방법을 선택해 주세요'
   when 'VENUE_ASSIGNED' then '만날 장소가 정해졌어요' else '식탁에 새 대화가 있어요' end,
  'body','나의 참가 현황에서 최신 안내를 확인해 주세요.') item
  from app_private.member_notifications n where n.user_id=actor and app_private.notification_visible(n,actor) order by n.created_at desc,n.id desc limit 50
 ) q;
 return jsonb_build_object('notifications',result,'unreadCount',unread);
end $$;
create function app_private.notifications_read(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); target uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'id')<>'{}'::jsonb or coalesce(payload->>'id','')!~'^[0-9a-fA-F-]{36}$' then raise exception 'VALIDATION_ERROR';end if;
 begin target:=(payload->>'id')::uuid;exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 update app_private.member_notifications n set read_at=coalesce(read_at,clock_timestamp()) where n.id=target and app_private.notification_visible(n,actor);
 if not found then raise exception 'FORBIDDEN';end if;
 return jsonb_build_object('read',true);
end $$;
create function app_private.notifications_tick() returns int
language plpgsql security definer set search_path='' as $$
declare e record; processed int:=0;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('notifications-tick',0)) then return 0;end if;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 for e in select o.* from app_private.match_outbox o where not exists(select 1 from app_private.notification_receipts r where r.event_id=o.id)
  order by o.created_at,o.id limit 50 loop
  if e.event_type='ALTERNATIVE_OFFERED' then
   insert into app_private.member_notifications(user_id,event_key,kind,application_id)
    select a.user_id,e.id::text,e.event_type,a.id from app_private.intake_applications a where a.id=e.aggregate_id and a.application_status='SUBMITTED' on conflict do nothing;
  else
   insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
    select distinct ta.user_id,e.id::text,e.event_type,ta.table_id,ta.application_id from app_private.table_assignments ta
    join app_private.intake_applications a on a.id=ta.application_id
    where ta.table_id=e.aggregate_id and a.application_status='SUBMITTED' and (ta.active or e.event_type='TABLE_INVALIDATED') on conflict do nothing;
  end if;
  insert into app_private.notification_receipts(event_id) values(e.id);processed:=processed+1;
 end loop;return processed;
end $$;
create function app_private.notification_chat_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.kind='MEMBER' then
  insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
  select ta.user_id,'chat:'||new.id::text,'CHAT_MESSAGE',ta.table_id,ta.application_id
  from app_private.chat_rooms r join app_private.table_assignments ta on ta.table_id=r.table_id
  where r.id=new.room_id and ta.active and ta.user_id<>(select user_id from app_private.chat_members where id=new.member_id)
  on conflict do nothing;
 end if;return new;
end $$;
create trigger notification_chat after insert on app_private.chat_messages for each row execute function app_private.notification_chat_trigger();
create function app_private.notification_venue_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.active then
  insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
   select ta.user_id,'venue:'||new.id::text,'VENUE_ASSIGNED',ta.table_id,ta.application_id from app_private.table_assignments ta
   where ta.table_id=new.table_id and ta.active on conflict do nothing;
 end if;return new;
end $$;
create trigger notification_venue after insert on app_private.venue_allocations for each row execute function app_private.notification_venue_trigger();
revoke all on function app_private.notification_visible(app_private.member_notifications,uuid),app_private.notifications_get(),app_private.notifications_read(jsonb),app_private.notifications_tick(),app_private.notification_chat_trigger(),app_private.notification_venue_trigger() from public,anon,authenticated;
grant execute on function app_private.notifications_get(),app_private.notifications_read(jsonb) to app_member_api;
select cron.schedule('serendipity-notifications-tick','* * * * *','select app_private.notifications_tick();');
