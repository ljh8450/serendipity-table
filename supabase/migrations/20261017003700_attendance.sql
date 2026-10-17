-- ATT-004: server-owned check-in window and reviewed, never automatic, no-shows.
create table app_private.attendance_records (
 assignment_id uuid primary key references app_private.table_assignments(id),
 checked_in_at timestamptz, closed_at timestamptz,
 review_status text not null default 'NONE' check(review_status in ('NONE','PENDING','ATTENDED','NO_SHOW')),
 policy_version text not null default 'attendance-v1'
);
create table app_private.attendance_actions (
 id bigint generated always as identity primary key,
 assignment_id uuid not null references app_private.table_assignments(id),
 actor_id uuid not null references auth.users(id), request_key uuid not null,
 action text not null check(action in ('CHECK_IN','ATTENDED','NO_SHOW')),
 reason text, occurred_at timestamptz not null default clock_timestamp(),
 unique(actor_id,request_key)
);
alter table app_private.attendance_records enable row level security;
alter table app_private.attendance_actions enable row level security;
revoke all on app_private.attendance_records,app_private.attendance_actions from public,anon,authenticated,app_member_api;

create function app_private.attendance_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 return jsonb_build_object('attendances',coalesce((select jsonb_agg(item order by starts_at desc,id) from (
 select ta.id,s.starts_at,jsonb_build_object('assignmentId',ta.id,'applicationId',a.id,'startsAt',s.starts_at,
 'opensAt',s.starts_at-interval '30 minutes','closesAt',s.starts_at+interval '3 hours',
 'status',a.attendance_status,'checkedInAt',r.checked_in_at,'reviewStatus',coalesce(r.review_status,'NONE'),
 'canCheckIn',a.attendance_status='SCHEDULED' and r.checked_in_at is null and clock_timestamp()>=s.starts_at-interval '30 minutes' and clock_timestamp()<s.starts_at+interval '3 hours') item
 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id join app_private.intake_applications a on a.id=ta.application_id
 left join app_private.attendance_records r on r.assignment_id=ta.id
 where ta.user_id=actor and ta.active and t.status='CONFIRMED' and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED'
 order by s.starts_at desc,ta.id limit 20) q),'[]'::jsonb));
end $$;

create function app_private.attendance_check_in(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();target uuid;req uuid;ta app_private.table_assignments;start_time timestamptz;prior app_private.attendance_actions;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>2 or not(payload ?& array['assignmentId','requestKey'])
 or coalesce(payload->>'assignmentId','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'requestKey','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'VALIDATION_ERROR';end if;
 target:=(payload->>'assignmentId')::uuid;req:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 select * into ta from app_private.table_assignments where id=target and user_id=actor and active;
 if ta.id is null or not exists(select 1 from app_private.dining_tables t join app_private.intake_applications a on a.id=ta.application_id
 where t.id=ta.table_id and t.status='CONFIRMED' and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED') then raise exception 'FORBIDDEN';end if;
 select * into prior from app_private.attendance_actions where actor_id=actor and request_key=req;
 if prior.id is not null then
  if prior.assignment_id<>target or prior.action<>'CHECK_IN' then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  return app_private.attendance_get();
 end if;
 if exists(select 1 from app_private.attendance_records where assignment_id=target and checked_in_at is not null) then return app_private.attendance_get();end if;
 select s.starts_at into start_time from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id where t.id=ta.table_id;
 if clock_timestamp()<start_time-interval '30 minutes' or clock_timestamp()>=start_time+interval '3 hours'
 or (select attendance_status from app_private.intake_applications where id=ta.application_id)<>'SCHEDULED' then raise exception 'CHECK_IN_CLOSED';end if;
 insert into app_private.attendance_records(assignment_id,checked_in_at) values(target,clock_timestamp());
 update app_private.intake_applications set attendance_status='ATTENDED' where id=ta.application_id;
 insert into app_private.attendance_actions(assignment_id,actor_id,request_key,action) values(target,actor,req,'CHECK_IN');
 insert into app_private.member_audit(actor_id,action) values(actor,'ATTENDANCE_CHECK_IN');
 return app_private.attendance_get();
end $$;

create function app_private.attendance_tick() returns int
language plpgsql security definer set search_path='' as $$
declare count_n int;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 if not pg_try_advisory_xact_lock(hashtextextended('attendance-state',0)) then return 0;end if;
 insert into app_private.attendance_records(assignment_id,closed_at,review_status)
 select ta.id,clock_timestamp(),case when a.attendance_status='ATTENDED' then 'NONE' else 'PENDING' end
 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id join app_private.intake_applications a on a.id=ta.application_id
 where ta.active and t.status='CONFIRMED' and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED'
 and a.attendance_status in ('SCHEDULED','ATTENDED') and clock_timestamp()>=s.starts_at+interval '3 hours'
 on conflict(assignment_id) do update set closed_at=excluded.closed_at where attendance_records.closed_at is null;
 get diagnostics count_n=row_count;return count_n;
end $$;

create function app_private.operations_attendance_get() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.operator_actor();
 return jsonb_build_object('reviews',coalesce((select jsonb_agg(item order by closed_at desc,assignment_id) from (
 select r.closed_at,r.assignment_id,jsonb_build_object('assignmentId',r.assignment_id,'applicationId',a.id,'startsAt',s.starts_at,
 'status',a.attendance_status,'reviewStatus',r.review_status,'closedAt',r.closed_at,
 'canReview',ta.active and t.status='CONFIRMED' and a.application_status='SUBMITTED' and a.matching_status='CONFIRMED',
 'actions',coalesce((select jsonb_agg(jsonb_build_object('action',h.action,'at',h.occurred_at) order by h.id) from app_private.attendance_actions h where h.assignment_id=r.assignment_id),'[]'::jsonb)) item
 from app_private.attendance_records r join app_private.table_assignments ta on ta.id=r.assignment_id
 join app_private.intake_applications a on a.id=ta.application_id join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id where r.review_status<>'NONE'
 order by r.closed_at desc,r.assignment_id limit 100) q),'[]'::jsonb));
end $$;

create function app_private.operations_attendance_review(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();target uuid;req uuid;outcome text;note text;prior app_private.attendance_actions;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>4 or not(payload ?& array['assignmentId','requestKey','outcome','reason'])
 or coalesce(payload->>'assignmentId','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'requestKey','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'outcome','') not in ('ATTENDED','NO_SHOW') or jsonb_typeof(payload->'reason') is distinct from 'string'
 or length(btrim(payload->>'reason')) not between 5 and 500 then raise exception 'VALIDATION_ERROR';end if;
 target:=(payload->>'assignmentId')::uuid;req:=(payload->>'requestKey')::uuid;outcome:=payload->>'outcome';note:=btrim(payload->>'reason');
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 if not exists(select 1 from app_private.attendance_records r join app_private.table_assignments ta on ta.id=r.assignment_id
 join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_applications a on a.id=ta.application_id
 where r.assignment_id=target and r.review_status<>'NONE' and r.closed_at is not null and ta.active and t.status='CONFIRMED'
 and a.application_status='SUBMITTED' and a.matching_status='CONFIRMED') then raise exception 'ATTENDANCE_CONFLICT';end if;
 select * into prior from app_private.attendance_actions where actor_id=actor and request_key=req;
 if prior.id is not null then
  if prior.assignment_id<>target or prior.action<>outcome or prior.reason<>note then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  return app_private.operations_attendance_get();
 end if;
 update app_private.attendance_records set review_status=outcome where assignment_id=target;
 update app_private.intake_applications a set attendance_status=outcome from app_private.table_assignments ta where ta.id=target and a.id=ta.application_id;
 insert into app_private.attendance_actions(assignment_id,actor_id,request_key,action,reason) values(target,actor,req,outcome,note);
 insert into app_private.member_audit(actor_id,action) values(actor,'ATTENDANCE_REVIEW');
 return app_private.operations_attendance_get();
end $$;
revoke all on function app_private.attendance_get(),app_private.attendance_check_in(jsonb),app_private.attendance_tick(),app_private.operations_attendance_get(),app_private.operations_attendance_review(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.attendance_get(),app_private.attendance_check_in(jsonb),app_private.operations_attendance_get(),app_private.operations_attendance_review(jsonb) to app_member_api;
select cron.schedule('serendipity-attendance-tick','* * * * *','select app_private.attendance_tick()');
