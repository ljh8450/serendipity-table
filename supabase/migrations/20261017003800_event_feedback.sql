-- FDB-005: participant-owned event ratings and one unanswered reminder.
create table app_private.event_feedback (
 assignment_id uuid primary key references app_private.table_assignments(id) on delete cascade,
 user_id uuid not null references auth.users(id), request_key uuid not null, ratings jsonb not null, submitted_at timestamptz not null default clock_timestamp(),
 policy_version text not null default 'feedback-v1',unique(user_id,request_key)
);
create table app_private.feedback_jobs (
 id uuid primary key default gen_random_uuid(), assignment_id uuid not null references app_private.table_assignments(id) on delete cascade,
 kind text not null check(kind in ('REQUEST','REMINDER')), due_at timestamptz not null,
 status text not null default 'WAITING' check(status in ('WAITING','DONE','CANCELED','EXCEPTION')),
 attempts int not null default 0, last_error text, finished_at timestamptz,
 unique(assignment_id,kind)
);
create index on app_private.feedback_jobs(due_at) where status='WAITING';
alter table app_private.event_feedback enable row level security;
alter table app_private.feedback_jobs enable row level security;
revoke all on app_private.event_feedback,app_private.feedback_jobs from public,anon,authenticated,app_member_api;

create function app_private.feedback_eligible(target uuid,actor uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_applications a on a.id=ta.application_id join app_private.intake_event_slots s on s.id=t.slot_id
 join app_private.member_accounts m on m.user_id=ta.user_id
 where ta.id=target and ta.user_id=actor and ta.active and t.status='CONFIRMED' and a.application_status='SUBMITTED'
 and a.payment_status='PAID' and a.matching_status='CONFIRMED' and a.attendance_status='ATTENDED' and not m.restricted
 and clock_timestamp()>=s.starts_at+interval '3 hours')
$$;
create function app_private.feedback_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 return jsonb_build_object('events',coalesce((select jsonb_agg(item order by starts_at desc,id) from (
 select ta.id,s.starts_at,jsonb_build_object('assignmentId',ta.id,'startsAt',s.starts_at,'deadlineAt',s.starts_at+interval '3 hours 7 days',
 'canSubmit',f.assignment_id is null and clock_timestamp()<s.starts_at+interval '3 hours 7 days',
 'submittedAt',f.submitted_at,'ratings',f.ratings) item
 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id left join app_private.event_feedback f on f.assignment_id=ta.id
 where ta.user_id=actor and app_private.feedback_eligible(ta.id,actor) order by s.starts_at desc,ta.id limit 20) q),'[]'::jsonb));
end $$;
create function app_private.feedback_submit(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();target uuid;req uuid;ratings jsonb;k text;prior app_private.event_feedback;deadline timestamptz;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>3 or not(payload ?& array['assignmentId','requestKey','ratings'])
 or coalesce(payload->>'assignmentId','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'requestKey','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or jsonb_typeof(payload->'ratings') is distinct from 'object' then raise exception 'VALIDATION_ERROR';end if;
 target:=(payload->>'assignmentId')::uuid;req:=(payload->>'requestKey')::uuid;ratings:=payload->'ratings';
 if (select count(*) from jsonb_object_keys(ratings))<>5 or not(ratings ?& array['atmosphere','conversation','venue','revisit','recommend']) then raise exception 'VALIDATION_ERROR';end if;
 foreach k in array array['atmosphere','conversation','venue'] loop
  if jsonb_typeof(ratings->k) is distinct from 'number' or coalesce(ratings->>k,'')!~'^[1-5]$' then raise exception 'VALIDATION_ERROR';end if;
 end loop;
 if jsonb_typeof(ratings->'revisit') is distinct from 'boolean' or jsonb_typeof(ratings->'recommend') is distinct from 'boolean' then raise exception 'VALIDATION_ERROR';end if;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 perform pg_advisory_xact_lock(hashtextextended('feedback-state',0));
 if not app_private.feedback_eligible(target,actor) then raise exception 'FORBIDDEN';end if;
 if exists(select 1 from app_private.event_feedback where user_id=actor and request_key=req and assignment_id<>target) then raise exception 'IDEMPOTENCY_CONFLICT';end if;
 select * into prior from app_private.event_feedback where assignment_id=target;
 if prior.assignment_id is not null then
  if prior.request_key<>req or prior.ratings<>ratings then raise exception 'FEEDBACK_CONFLICT';end if;
  return app_private.feedback_get();
 end if;
 select s.starts_at+interval '3 hours 7 days' into deadline from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id where ta.id=target;
 if clock_timestamp()>=deadline then raise exception 'FEEDBACK_CLOSED';end if;
 insert into app_private.event_feedback(assignment_id,user_id,request_key,ratings) values(target,actor,req,ratings);
 update app_private.feedback_jobs set status='CANCELED' where assignment_id=target and status in ('WAITING','EXCEPTION');
 perform pg_advisory_xact_lock(hashtextextended('push-state',0));
 update app_private.push_jobs p set status='CANCELED',lease_until=null,token=null
 from app_private.member_notifications n join app_private.feedback_jobs j on n.event_key='feedback:'||j.id::text
 where j.assignment_id=target and p.notification_id=n.id and p.status in ('PENDING','RUNNING','EXCEPTION');
 insert into app_private.member_audit(actor_id,action) values(actor,'FEEDBACK_SUBMIT');
 return app_private.feedback_get();
end $$;

alter table app_private.member_notifications drop constraint member_notifications_kind_check;
alter table app_private.member_notifications add constraint member_notifications_kind_check check(kind in ('TABLE_CONFIRMED','TABLE_UPDATED','TABLE_INVALIDATED','ALTERNATIVE_OFFERED','VENUE_ASSIGNED','CHAT_MESSAGE','PUSH_TEST','EVENT_GUIDE','EVENT_REMINDER','EVENT_CONTENT','FEEDBACK_REQUEST','FEEDBACK_REMINDER'));
alter function app_private.notification_visible(app_private.member_notifications,uuid) rename to notification_visible_v2;
create function app_private.notification_visible(n app_private.member_notifications,actor uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select case when n.kind in ('FEEDBACK_REQUEST','FEEDBACK_REMINDER') then n.user_id=actor and exists(
 select 1 from app_private.feedback_jobs j join app_private.table_assignments ta on ta.id=j.assignment_id
 join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id
 where n.event_key='feedback:'||j.id::text and app_private.feedback_eligible(ta.id,actor)
 and clock_timestamp()<s.starts_at+interval '3 hours 7 days' and not exists(select 1 from app_private.event_feedback f where f.assignment_id=ta.id))
 else app_private.notification_visible_v2(n,actor) end
$$;
create function app_private.feedback_tick() returns int
language plpgsql security definer set search_path='' as $$
declare work record;count_n int:=0;code text;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 if not pg_try_advisory_xact_lock(hashtextextended('feedback-state',0)) then return 0;end if;
 insert into app_private.feedback_jobs(assignment_id,kind,due_at)
 select ta.id,'REQUEST',clock_timestamp() from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id
 where app_private.feedback_eligible(ta.id,ta.user_id) and clock_timestamp()<s.starts_at+interval '3 hours 7 days'
 and not exists(select 1 from app_private.event_feedback f where f.assignment_id=ta.id) on conflict do nothing;
 insert into app_private.feedback_jobs(assignment_id,kind,due_at)
 select j.assignment_id,'REMINDER',j.finished_at+interval '24 hours' from app_private.feedback_jobs j
 where j.kind='REQUEST' and j.status='DONE' and not exists(select 1 from app_private.event_feedback f where f.assignment_id=j.assignment_id) on conflict do nothing;
 for work in select j.*,ta.user_id,ta.table_id,ta.application_id,s.starts_at from app_private.feedback_jobs j
 join app_private.table_assignments ta on ta.id=j.assignment_id join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id where j.status='WAITING' and j.due_at<=clock_timestamp()
 order by j.due_at,j.id limit 50 for update of j skip locked loop
  if not app_private.feedback_eligible(work.assignment_id,work.user_id) or clock_timestamp()>=work.starts_at+interval '3 hours 7 days'
  or exists(select 1 from app_private.event_feedback where assignment_id=work.assignment_id) then
   update app_private.feedback_jobs set status='CANCELED' where id=work.id;continue;
  end if;
  begin
   insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
   values(work.user_id,'feedback:'||work.id::text,'FEEDBACK_'||work.kind,work.table_id,work.application_id) on conflict do nothing;
   update app_private.feedback_jobs set status='DONE',finished_at=clock_timestamp(),attempts=attempts+1,last_error=null where id=work.id;
   count_n:=count_n+1;
  exception when others then
   code:='FEEDBACK_DELIVERY_FAILED';
   update app_private.feedback_jobs set attempts=attempts+1,status=case when attempts>=2 then 'EXCEPTION' else 'WAITING' end,last_error=code,due_at=clock_timestamp()+interval '1 minute' where id=work.id;
  end;
 end loop;return count_n;
end $$;
create function app_private.operations_feedback_get() returns jsonb
language plpgsql security definer set search_path='' as $$
begin perform app_private.operator_actor();
 return jsonb_build_object('jobs',coalesce((select jsonb_agg(item order by attention desc,due_at desc,id) from (
 select id,due_at,status='EXCEPTION' attention,jsonb_build_object('id',id,'kind',kind,'status',status,'attempts',attempts,'dueAt',due_at,'lastError',last_error) item
 from app_private.feedback_jobs order by (status='EXCEPTION') desc,due_at desc,id limit 100) q),'[]'::jsonb));
end $$;
create function app_private.operations_feedback_retry(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();target uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'jobId')<>'{}'::jsonb or coalesce(payload->>'jobId','')!~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'VALIDATION_ERROR';end if;
 target:=(payload->>'jobId')::uuid;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 perform pg_advisory_xact_lock(hashtextextended('feedback-state',0));
 update app_private.feedback_jobs j set status='WAITING',attempts=0,last_error=null,due_at=clock_timestamp()
 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id
 where j.id=target and j.assignment_id=ta.id and j.status='EXCEPTION' and app_private.feedback_eligible(ta.id,ta.user_id)
 and clock_timestamp()<s.starts_at+interval '3 hours 7 days' and not exists(select 1 from app_private.event_feedback f where f.assignment_id=ta.id);
 if not found then raise exception 'FEEDBACK_CONFLICT';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'FEEDBACK_RETRY');return app_private.operations_feedback_get();
end $$;
revoke all on function app_private.feedback_eligible(uuid,uuid),app_private.feedback_get(),app_private.feedback_submit(jsonb),app_private.feedback_tick(),app_private.operations_feedback_get(),app_private.operations_feedback_retry(jsonb),app_private.notification_visible(app_private.member_notifications,uuid) from public,anon,authenticated,app_member_api;
grant execute on function app_private.feedback_get(),app_private.feedback_submit(jsonb),app_private.operations_feedback_get(),app_private.operations_feedback_retry(jsonb) to app_member_api;
select cron.schedule('serendipity-feedback-tick','* * * * *','select app_private.feedback_tick()');

create or replace function app_private.notifications_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); result jsonb; unread bigint;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 select count(*) into unread from app_private.member_notifications n where n.user_id=actor and n.read_at is null and app_private.notification_visible(n,actor);
 select coalesce(jsonb_agg(item order by created_at desc,id desc),'[]'::jsonb) into result from (
  select n.created_at,n.id,jsonb_build_object('id',n.id,'kind',n.kind,'createdAt',n.created_at,'read',n.read_at is not null,
  'title',case n.kind when 'FEEDBACK_REQUEST' then '식탁은 어떠셨나요? 평가를 남겨 주세요' when 'FEEDBACK_REMINDER' then '식탁 평가를 한 번 더 부탁드려요' when 'TABLE_CONFIRMED' then '식탁이 확정됐어요' when 'TABLE_UPDATED' then '식탁 안내가 변경됐어요'
   when 'TABLE_INVALIDATED' then '식탁을 다시 준비하고 있어요' when 'ALTERNATIVE_OFFERED' then '다음 참가 방법을 선택해 주세요'
   when 'EVENT_REMINDER' then '식탁 준비 안내가 도착했어요' when 'EVENT_CONTENT' then '대화 주제와 게임을 확인해 주세요' when 'EVENT_GUIDE' then '최신 식탁 공지를 확인해 주세요' when 'PUSH_TEST' then '푸시 수신 확인을 요청했어요' when 'VENUE_ASSIGNED' then '만날 장소가 정해졌어요' else '식탁에 새 대화가 있어요' end,
  'body','나의 참가 현황에서 최신 안내를 확인해 주세요.') item
  from app_private.member_notifications n where n.user_id=actor and app_private.notification_visible(n,actor) order by n.created_at desc,n.id desc limit 50
 ) q;
 return jsonb_build_object('notifications',result,'unreadCount',unread);
end $$;


-- Wait for attendance mutations: the new feedback worker must not starve closing.
create or replace function app_private.attendance_tick() returns int
language plpgsql security definer set search_path='' as $$
declare count_n int;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 insert into app_private.attendance_records(assignment_id,closed_at,review_status)
 select ta.id,clock_timestamp(),case when a.attendance_status='ATTENDED' then 'NONE' else 'PENDING' end
 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id join app_private.intake_applications a on a.id=ta.application_id
 where ta.active and t.status='CONFIRMED' and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED'
 and a.attendance_status in ('SCHEDULED','ATTENDED') and clock_timestamp()>=s.starts_at+interval '3 hours'
 on conflict(assignment_id) do update set closed_at=excluded.closed_at where attendance_records.closed_at is null;
 get diagnostics count_n=row_count;return count_n;
end $$;

