-- PRD 11: operator-editable plain text, immutable versions and delivery snapshots.
create table app_private.message_templates(
 version uuid primary key default gen_random_uuid(),kind text not null check(kind in('GUIDE','D1','START','CURATION','ALTERNATIVE')),
 body text not null check(length(btrim(body)) between 1 and 500),active boolean not null default true,
 created_at timestamptz not null default clock_timestamp(),actor_id uuid
);
create unique index message_templates_active on app_private.message_templates(kind) where active;
insert into app_private.message_templates(kind,body) values
 ('GUIDE','만남에 필요한 안내를 확인해 주세요. 장소가 바뀌면 최신 참가 현황을 확인해 주세요.'),
 ('D1','곧 만날 식탁을 준비해 주세요. 일정과 장소, 취소·환불 안내를 확인해 주세요.'),
 ('START','서로 원하는 만큼 소개하고, 답변을 건너뛰어도 괜찮아요. 편안하게 대화를 시작해 주세요.'),
 ('CURATION','공통 관심사에서 시작해 서로의 이야기를 들어 보세요.'),
 ('ALTERNATIVE','선택한 일정에서 식탁을 만들지 못했어요. 참가 현황에서 다른 일정·보관·환불을 직접 선택해 주세요.');
alter table app_private.message_templates enable row level security;
revoke all on app_private.message_templates from public,anon,authenticated,app_member_api;
create function app_private.operations_templates_get() returns jsonb
language plpgsql security definer set search_path='' as $$
begin perform app_private.operator_actor();
 return jsonb_build_object('templates',(select jsonb_agg(jsonb_build_object('kind',kind,'version',version,'body',body,'createdAt',created_at) order by kind) from app_private.message_templates where active));
end $$;
create function app_private.operations_templates_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();old app_private.message_templates;begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['kind','expectedVersion','body'] or (payload-array['kind','expectedVersion','body'])<>'{}'::jsonb
 or exists(select 1 from jsonb_each(payload) where jsonb_typeof(value)<>'string') or length(btrim(payload->>'body')) not between 1 and 500
 or payload->>'kind' not in('GUIDE','D1','START','CURATION','ALTERNATIVE') then raise exception 'VALIDATION_ERROR';end if;
 perform pg_advisory_xact_lock(hashtextextended('message-template:'||(payload->>'kind'),0));
 select * into old from app_private.message_templates where kind=payload->>'kind' and active for update;
 if old.version::text is distinct from payload->>'expectedVersion' then raise exception 'JOB_CONFLICT';end if;
 if old.body=payload->>'body' then return app_private.operations_templates_get();end if;
 update app_private.message_templates set active=false where version=old.version;
 insert into app_private.message_templates(kind,body,actor_id) values(old.kind,btrim(payload->>'body'),actor);
 insert into app_private.member_audit(actor_id,action) values(actor,'MESSAGE_TEMPLATE_'||old.kind);
 return app_private.operations_templates_get();
end $$;
alter table app_private.member_notifications add column template_snapshot jsonb;
create function app_private.notification_template_snapshot() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.kind='ALTERNATIVE_OFFERED' then
  select jsonb_build_object('version',version,'body',body) into new.template_snapshot from app_private.message_templates where kind='ALTERNATIVE' and active;
 end if;
 return new;
end $$;
create trigger notification_template_snapshot before insert on app_private.member_notifications for each row execute function app_private.notification_template_snapshot();
revoke all on function app_private.operations_templates_get(),app_private.operations_templates_save(jsonb),app_private.notification_template_snapshot() from public,anon,authenticated;
grant execute on function app_private.operations_templates_get(),app_private.operations_templates_save(jsonb) to app_member_api;

create or replace function app_private.content_apply(job_uuid uuid) returns void
language plpgsql security definer set search_path='' as $$
declare j app_private.content_jobs;t app_private.dining_tables;s app_private.intake_event_slots;r app_private.chat_rooms;
 v app_private.venue_inventory;u record;messages jsonb:='[]';content jsonb;body text;ordinal int:=0;cutoff timestamptz;kind text;begin
 select * into j from app_private.content_jobs where id=job_uuid;
 select * into t from app_private.dining_tables where id=j.table_id;
 select * into s from app_private.intake_event_slots where id=t.slot_id;
 if t.status is distinct from 'CONFIRMED' then raise exception 'CONTENT_STALE';end if;
 if clock_timestamp()<j.scheduled_at or (j.kind='START' and clock_timestamp()<s.starts_at) or (j.kind='D1' and clock_timestamp()<s.starts_at-interval '24 hours') then raise exception 'CONTENT_EARLY';end if;
 if clock_timestamp()>=s.starts_at+(case when j.kind='D1' then interval '0' else interval '3 hours' end) then raise exception 'CONTENT_MISSED_WINDOW';end if;
 if j.kind='GUIDE' and j.revision<>app_private.content_location_revision(t.id) then raise exception 'CONTENT_STALE';end if;
 select * into r from app_private.chat_rooms where table_id=t.id and status='OPEN';
 if r.id is null then raise exception 'CONTENT_ROOM_PENDING';end if;
 if exists(select 1 from app_private.table_assignments ta left join app_private.member_accounts ma on ma.user_id=ta.user_id where ta.table_id=t.id and ta.active and ma.user_id is null) then raise exception 'CONTENT_STALE';end if;
 if (select count(*) from app_private.table_assignments where table_id=t.id and active) not between 4 and 6 then raise exception 'CONTENT_STALE';end if;
 for u in select ta.user_id,a.application_status,a.payment_status,a.matching_status,ma.restricted from app_private.table_assignments ta
 join app_private.intake_applications a on a.id=ta.application_id join app_private.member_accounts ma on ma.user_id=ta.user_id where ta.table_id=t.id and ta.active loop
  if u.restricted or u.application_status<>'SUBMITTED' or u.payment_status<>'PAID' or u.matching_status<>'CONFIRMED' then raise exception 'CONTENT_STALE';end if;
  perform app_private.chat_authorize(r.id,u.user_id);
 end loop;
 if j.kind='START' then
  content:=app_private.content_topics(t.id);
  for body in select value from jsonb_array_elements_text(content->'topics') loop ordinal:=ordinal+1;messages:=messages||jsonb_build_array('대화 주제 '||ordinal::text||': '||body);end loop;
  messages:=messages||jsonb_build_array('선택 게임: '||(content->>'game'));kind:='EVENT_CONTENT';
 else
  select vi.* into v from app_private.venue_allocations va join app_private.venue_inventory vi on vi.id=va.inventory_id
   where va.table_id=t.id and va.active and app_private.venue_compatible(vi,t.id);
  if j.kind='D1' and v.id is null then raise exception 'CONTENT_VENUE_PENDING';end if;
  cutoff:=coalesce(s.refund_cutoff_at,app_private.refund_cutoff(s.starts_at));
  messages:=jsonb_build_array(case when j.kind='D1' then '다가오는 식탁 안내' else '최신 식탁 안내' end||': '||to_char(s.starts_at at time zone 'Asia/Seoul','YYYY.MM.DD HH24:MI')||' (서울) · '||s.region_label||'. 게시 시점 정보이며 장소 변경 시 최신 공지와 참가 현황을 확인해 주세요.');
  if v.id is null then messages:=messages||jsonb_build_array('기존 장소가 회수됐거나 장소를 준비하고 있어요. 확정 전 방문하지 말고 최신 참가 현황을 확인해 주세요.');
  else messages:=messages||jsonb_build_array('식당: '||v.name,'주소: '||v.address,'예약명: '||v.reservation_name||' · 식사 가격 '||v.meal_price_krw::text||'원. 지도는 참가 현황에서 확인해 주세요.');end if;
  messages:=messages||jsonb_build_array('취소·환불: 자발 취소 환불은 '||to_char(cutoff at time zone 'Asia/Seoul','YYYY.MM.DD HH24:MI')||' (서울) 정각부터 불가해요. 행사 당일 취소는 제한되며 매칭 실패 해결은 별도 안내를 따라 주세요. 서로 원하는 만큼 소개하고 대화하며, 시작 시각에 대화 주제와 선택 게임이 게시돼요.');
  if j.kind='GUIDE' then messages:=messages||jsonb_build_array('식탁 이야기 방향: '||(app_private.content_topics(t.id)->>'curation')||' 소개와 답변은 원하는 만큼만 나눠도 좋아요.');end if;
  content:=jsonb_build_object('templateVersion','guide-v1','allocationRevision',app_private.content_location_revision(t.id));kind:=case when j.kind='D1' then 'EVENT_REMINDER' else 'EVENT_GUIDE' end;
 end if;
 -- Resolve the active text at dispatch; published messages retain these versions.
 content:=content||jsonb_build_object('operatorTemplates',(select jsonb_agg(jsonb_build_object('kind',mt.kind,'version',mt.version,'body',mt.body) order by mt.kind) from app_private.message_templates mt where mt.active and (mt.kind=j.kind or (j.kind='GUIDE' and mt.kind='CURATION'))));
 messages:=(select coalesce(jsonb_agg(x->>'body'),'[]'::jsonb) from jsonb_array_elements(content->'operatorTemplates') x)||messages;
 ordinal:=0;
 for body in select value from jsonb_array_elements_text(messages) loop
  ordinal:=ordinal+1;insert into app_private.chat_messages(room_id,system_key,kind,body) values(r.id,'content:'||j.id::text||':'||ordinal::text,'SYSTEM',body) on conflict(room_id,system_key) do nothing;
 end loop;
 insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
  select ta.user_id,'content:'||j.id::text,kind,t.id,ta.application_id from app_private.table_assignments ta where ta.table_id=t.id and ta.active on conflict do nothing;
 update app_private.content_jobs set snapshot=content||jsonb_build_object('messages',messages),status='DONE',finished_at=clock_timestamp(),last_error=null where id=j.id;
end $$;

alter function app_private.notifications_get() rename to notifications_get_before_templates;
revoke all on function app_private.notifications_get_before_templates() from app_member_api;
create function app_private.notifications_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();dto jsonb;begin
 dto:=app_private.notifications_get_before_templates();
 return jsonb_set(dto,'{notifications}',(select coalesce(jsonb_agg(case when n.template_snapshot->>'body' is not null then item||jsonb_build_object('body',n.template_snapshot->>'body') else item end order by ordinal),'[]') from jsonb_array_elements(dto->'notifications') with ordinality q(item,ordinal) left join app_private.member_notifications n on n.id=(item->>'id')::uuid and n.user_id=actor));
end $$;
revoke all on function app_private.notifications_get() from public,anon,authenticated;
grant execute on function app_private.notifications_get() to app_member_api;
