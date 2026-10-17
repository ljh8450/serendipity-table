-- SAF-003: independent participation state; financial rights and reports stay accessible.
create table app_private.safety_accounts(user_id uuid primary key references auth.users(id) on delete cascade,state text not null default 'ACTIVE' check(state in('ACTIVE','WARNING','RESTRICTED','BANNED')),revision int not null default 0 check(revision>=0));
alter table app_private.intake_applications drop constraint intake_applications_resolution_reason_check;
alter table app_private.intake_applications add constraint intake_applications_resolution_reason_check check(resolution_reason in('matching_failure','voluntary','voluntary_late','safety_hold'));
alter table app_private.refund_attempts drop constraint refund_attempts_reason_check;
alter table app_private.refund_attempts add constraint refund_attempts_reason_check check(reason in('voluntary','matching_failure','safety_hold'));
create table app_private.safety_reviewers(user_id uuid primary key references auth.users(id) on delete cascade);
create table app_private.safety_exclusions(
 user_low uuid not null references auth.users(id) on delete cascade,user_high uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(),primary key(user_low,user_high),check(user_low<user_high));
create table app_private.safety_reports(
 id uuid primary key default gen_random_uuid(),reporter_id uuid not null references auth.users(id) on delete cascade,target_id uuid not null references auth.users(id) on delete cascade,
 assignment_id uuid not null references app_private.table_assignments(id) on delete cascade,peer_id uuid not null references app_private.table_assignments(id) on delete cascade,
 category text not null check(category in('HARASSMENT','UNWANTED_CONTACT','OTHER')),details text not null check(length(btrim(details)) between 10 and 2000),
 status text not null default 'PENDING' check(status in('PENDING','REVIEWED','DISMISSED')),created_at timestamptz not null default clock_timestamp(),check(reporter_id<>target_id));
create index safety_report_owner on app_private.safety_reports(reporter_id,created_at desc);
create table app_private.safety_commands(
 actor_id uuid not null references auth.users(id) on delete cascade,target_id uuid references auth.users(id) on delete cascade,request_key uuid not null,input_hash text not null,kind text not null check(kind in('REPORT','BLOCK','REVIEW')),
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_key));
create index safety_command_subject on app_private.safety_commands(actor_id,target_id) where kind in('REPORT','BLOCK');
create table app_private.safety_actions(
 id bigint generated always as identity primary key,actor_id uuid not null references auth.users(id) on delete cascade,target_id uuid not null references auth.users(id) on delete cascade,
 case_type text not null check(case_type in('REPORT','ATTENDANCE','CANCELLATION')),case_id uuid not null,
 action text not null check(action in('REVIEWED','DISMISS','WARN','RESTRICT','BAN','RESTORE')),reason text not null check(length(btrim(reason)) between 5 and 500),
 revision int not null,state text not null,occurred_at timestamptz not null default clock_timestamp());
do $$ declare n text;begin foreach n in array array['safety_accounts','safety_reviewers','safety_exclusions','safety_reports','safety_commands','safety_actions'] loop
 execute format('alter table app_private.%I enable row level security',n);
 execute format('revoke all on app_private.%I from public,anon,authenticated,app_member_api',n);end loop;end $$;

create function app_private.safety_allowed(u uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.member_accounts where user_id=u and not restricted and coalesce((select state from app_private.safety_accounts s where s.user_id=u),'ACTIVE') in('ACTIVE','WARNING'))
$$;
create function app_private.safety_pair_blocked(a uuid,b uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.safety_exclusions where user_low=least(a,b) and user_high=greatest(a,b))
$$;
create or replace function app_private.match_pair_blocked(a uuid,b uuid) returns boolean language sql stable security definer set search_path='' as $$
 select app_private.safety_pair_blocked(a,b)
 or exists(select 1 from app_private.match_relations where user_low=least(a,b) and user_high=greatest(a,b))
 or exists(select 1 from app_private.effective_person_preferences p where p.value='AVOID' and ((p.user_id=a and p.target_user_id=b) or (p.user_id=b and p.target_user_id=a)))
$$;
create or replace function app_private.match_financially_eligible(a app_private.intake_applications) returns boolean language sql stable security definer set search_path='' as $$
 select a.application_status='SUBMITTED' and a.payment_status='PAID' and not a.credit_stored and app_private.safety_allowed(a.user_id)
 and case when a.membership_id is not null then app_private.membership_covers(a.membership_id,a.input->'slotIds')
 else exists(select 1 from app_private.payment_attempts p where p.id=a.credit_payment_id and p.user_id=a.user_id and p.outcome='success'
 and not exists(select 1 from app_private.refund_attempts r where r.payment_id=p.id and r.outcome='success')) end
$$;
create function app_private.safety_participation_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 -- Serializes submit/payment/transfer with review, in the existing matching-before-row order.
 if new.application_status='SUBMITTED' and not app_private.safety_allowed(new.user_id) and (
 tg_op='INSERT' or old.application_status is distinct from new.application_status or old.user_id is distinct from new.user_id
 or old.input is distinct from new.input or (new.payment_status='PAID' and old.payment_status is distinct from new.payment_status)
 or (new.matching_status in('WAITING','REALLOCATING','CONFIRMED') and old.matching_status is distinct from new.matching_status)) then raise exception 'PARTICIPATION_RESTRICTED';end if;
 return new;
end $$;
-- Statement-level fence avoids acquiring the global fence after a row lock.
create function app_private.safety_application_fence() returns trigger language plpgsql security definer set search_path='' as $$
begin perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));return null;end $$;
create trigger safety_application_fence before insert or update on app_private.intake_applications for each statement execute function app_private.safety_application_fence();
create trigger safety_participation_guard before insert or update on app_private.intake_applications for each row execute function app_private.safety_participation_guard();

create function app_private.safety_repair(req uuid) returns void language plpgsql security definer set search_path='' as $$
declare t record;begin
 for t in select d.id,d.slot_id,s.starts_at from app_private.dining_tables d join app_private.intake_event_slots s on s.id=d.slot_id
 where d.status='CONFIRMED' and s.starts_at>clock_timestamp() and (
 exists(select 1 from app_private.table_assignments a where a.table_id=d.id and a.active and not app_private.safety_allowed(a.user_id)) or
 exists(select 1 from app_private.table_assignments a join app_private.table_assignments b on b.table_id=a.table_id and a.id<b.id where a.table_id=d.id and a.active and b.active and app_private.safety_pair_blocked(a.user_id,b.user_id))) order by d.id for update of d loop
  update app_private.dining_tables set status='INVALIDATED' where id=t.id;
  update app_private.intake_applications a set matching_status=case when not app_private.safety_allowed(a.user_id) then 'ALTERNATIVE_OFFERED' when t.starts_at>clock_timestamp() then 'REALLOCATING' else 'EXCEPTION' end,
   resolution_reason=case when not app_private.safety_allowed(a.user_id) then 'safety_hold' else a.resolution_reason end
  where id in(select application_id from app_private.table_assignments where table_id=t.id and active);
  update app_private.table_assignments set active=false where table_id=t.id;
  if t.starts_at>clock_timestamp() then insert into app_private.match_jobs(job_key,slot_id,due_at) values('safety:'||req||':'||t.id,t.slot_id,clock_timestamp()) on conflict do nothing;end if;
  insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('safety:'||req||':'||t.id,'TABLE_INVALIDATED',t.id,jsonb_build_object('tableId',t.id)) on conflict do nothing;
 end loop;
 update app_private.intake_applications a set matching_status='ALTERNATIVE_OFFERED',resolution_reason='safety_hold'
 where a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status in('WAITING','REALLOCATING') and not app_private.safety_allowed(a.user_id);
end $$;
create or replace function app_private.chat_authorize(room_uuid uuid,actor_uuid uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare member_uuid uuid;begin
 select m.id into member_uuid from app_private.chat_members m join app_private.chat_rooms r on r.id=m.room_id join app_private.dining_tables t on t.id=r.table_id
 where r.id=room_uuid and r.status='OPEN' and t.status='CONFIRMED' and m.user_id=actor_uuid and m.active and app_private.safety_allowed(actor_uuid)
 and (select count(*) from app_private.table_assignments ta where ta.table_id=t.id and ta.active) between 4 and 6
 and exists(select 1 from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.table_id=t.id and ta.user_id=actor_uuid and ta.active and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED')
 and not exists(select 1 from app_private.table_assignments a join app_private.table_assignments b on b.table_id=a.table_id and a.id<b.id where a.table_id=t.id and a.active and b.active and app_private.safety_pair_blocked(a.user_id,b.user_id));
 if member_uuid is null then raise exception 'FORBIDDEN';end if;return member_uuid;
end $$;
create function app_private.safety_reviewer() returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();begin
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform 1 from app_private.safety_reviewers where user_id=actor for share;
 if not found then raise exception 'FORBIDDEN';end if;return actor;
end $$;
create function app_private.safety_get() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 return jsonb_build_object('state',coalesce((select state from app_private.safety_accounts where user_id=actor),'ACTIVE'),
 'reports',coalesce((select jsonb_agg(jsonb_build_object('id',id,'category',category,'status',status,'createdAt',created_at) order by created_at desc) from(select * from app_private.safety_reports where reporter_id=actor order by created_at desc limit 20) r),'[]'::jsonb),
 'contexts',coalesce((select jsonb_agg(item order by starts_at desc,id) from (
 select a.id,s.starts_at,jsonb_build_object('assignmentId',a.id,'startsAt',s.starts_at,'regionLabel',s.region_label,'peers',coalesce((
 select jsonb_agg(jsonb_build_object('peerId',p.id,'label','참가자 '||m.participant_no,'separated',exists(select 1 from app_private.safety_commands c where c.actor_id=actor and c.target_id=p.user_id and c.kind in('REPORT','BLOCK'))) order by m.participant_no)
 from app_private.table_assignments p join app_private.chat_rooms room on room.table_id=p.table_id join app_private.chat_members m on m.room_id=room.id and m.user_id=p.user_id
 where p.table_id=a.table_id and p.user_id<>actor),'[]'::jsonb)) item
 from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id join app_private.intake_event_slots s on s.id=t.slot_id where a.user_id=actor order by s.starts_at desc,a.id limit 20) q),'[]'::jsonb));
end $$;
create function app_private.safety_submit(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();target uuid;req uuid;hash text;prior app_private.safety_commands;begin
 if jsonb_typeof(payload) is distinct from 'object' or not(payload ?& array['assignmentId','peerId','requestKey','kind'])
 or coalesce(payload->>'kind','') not in('REPORT','BLOCK') or (select count(*) from jsonb_object_keys(payload))<>(case when payload->>'kind'='REPORT' then 6 else 4 end)
 or exists(select 1 from unnest(array['assignmentId','peerId','requestKey']) k where coalesce(payload->>k,'')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 or (payload->>'kind'='REPORT' and (not(payload ?& array['category','details']) or coalesce(payload->>'category','') not in('HARASSMENT','UNWANTED_CONTACT','OTHER') or jsonb_typeof(payload->'details') is distinct from 'string' or length(btrim(payload->>'details')) not between 10 and 2000)) then raise exception 'VALIDATION_ERROR';end if;
 req:=(payload->>'requestKey')::uuid;hash:=encode(sha256(convert_to((payload-'requestKey')::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 select p.user_id into target from app_private.table_assignments a join app_private.table_assignments p on p.table_id=a.table_id and p.user_id<>actor
 join app_private.chat_rooms r on r.table_id=p.table_id join app_private.chat_members m on m.room_id=r.id and m.user_id=p.user_id
 where a.id=(payload->>'assignmentId')::uuid and a.user_id=actor and p.id=(payload->>'peerId')::uuid;
 if target is null then raise exception 'FORBIDDEN';end if;
 select * into prior from app_private.safety_commands where actor_id=actor and request_key=req;
 if prior.actor_id is not null then if prior.input_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT';end if;return app_private.safety_get();end if;
 if payload->>'kind'='REPORT' then
  if (select count(*) from app_private.safety_reports where reporter_id=actor and created_at>clock_timestamp()-interval '24 hours')>=20 then raise exception 'SAFETY_RATE_LIMIT';end if;
  insert into app_private.safety_reports(reporter_id,target_id,assignment_id,peer_id,category,details) values(actor,target,(payload->>'assignmentId')::uuid,(payload->>'peerId')::uuid,payload->>'category',btrim(payload->>'details'));
 end if;
 insert into app_private.safety_exclusions(user_low,user_high) values(least(actor,target),greatest(actor,target)) on conflict do nothing;
 perform app_private.safety_repair(req);
 insert into app_private.safety_commands(actor_id,target_id,request_key,input_hash,kind) values(actor,target,req,hash,payload->>'kind');
 insert into app_private.member_audit(actor_id,action) values(actor,'SAFETY_'||(payload->>'kind'));
 return app_private.safety_get();
end $$;
create function app_private.operations_safety_get() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();begin
 return jsonb_build_object('canReview',exists(select 1 from app_private.safety_reviewers where user_id=actor),
 'cases',coalesce((select jsonb_agg(item order by at desc,id) from (
 select id,created_at at,jsonb_build_object('caseType','REPORT','caseId',id,'kind',category,'status',status,'at',created_at) item from app_private.safety_reports
 union all select r.assignment_id,r.closed_at,jsonb_build_object('caseType','ATTENDANCE','caseId',r.assignment_id,'kind','NO_SHOW','status',case when r.review_status='NO_SHOW' and i.attendance_status='NO_SHOW' then 'NO_SHOW' else 'CORRECTED' end,'at',r.closed_at) from app_private.attendance_records r join app_private.table_assignments a on a.id=r.assignment_id join app_private.intake_applications i on i.id=a.application_id where (r.review_status='NO_SHOW' and i.attendance_status='NO_SHOW') or exists(select 1 from app_private.safety_actions h where h.case_type='ATTENDANCE' and h.case_id=r.assignment_id)
 union all select a.id,coalesce((select max(m.created_at) from app_private.match_resolutions m where m.application_id=a.id and m.action='cancel'),a.submitted_at),jsonb_build_object('caseType','CANCELLATION','caseId',a.id,'kind','CANCELED_LATE','status',case when a.attendance_status='CANCELED_LATE' then 'REVIEW' else 'CORRECTED' end,'at',coalesce((select max(m.created_at) from app_private.match_resolutions m where m.application_id=a.id and m.action='cancel'),a.submitted_at)) from app_private.intake_applications a where a.attendance_status='CANCELED_LATE' or exists(select 1 from app_private.safety_actions h where h.case_type='CANCELLATION' and h.case_id=a.id)
 order by at desc,id limit 100) q),'[]'::jsonb));
end $$;
create function app_private.safety_case_target(case_kind text,case_uuid uuid) returns uuid language sql stable security definer set search_path='' as $$
 select target_id from app_private.safety_reports where case_kind='REPORT' and safety_reports.id=case_uuid
 union all select a.user_id from app_private.attendance_records r join app_private.table_assignments a on a.id=r.assignment_id join app_private.intake_applications i on i.id=a.application_id where case_kind='ATTENDANCE' and r.assignment_id=case_uuid and ((r.review_status='NO_SHOW' and i.attendance_status='NO_SHOW') or exists(select 1 from app_private.safety_actions h where h.case_type='ATTENDANCE' and h.case_id=r.assignment_id))
 union all select a.user_id from app_private.intake_applications a where case_kind='CANCELLATION' and a.id=case_uuid and (a.attendance_status='CANCELED_LATE' or exists(select 1 from app_private.safety_actions h where h.case_type='CANCELLATION' and h.case_id=a.id))
$$;
create function app_private.operations_safety_detail(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.safety_reviewer();target uuid;begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>2 or not(payload ?& array['caseType','caseId'])
 or coalesce(payload->>'caseType','') not in('REPORT','ATTENDANCE','CANCELLATION') or coalesce(payload->>'caseId','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'VALIDATION_ERROR';end if;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 target:=app_private.safety_case_target(payload->>'caseType',(payload->>'caseId')::uuid);if target is null then raise exception 'FORBIDDEN';end if;
 return jsonb_build_object('caseType',payload->>'caseType','caseId',payload->>'caseId','state',coalesce((select state from app_private.safety_accounts where user_id=target),'ACTIVE'),'revision',coalesce((select revision from app_private.safety_accounts where user_id=target),0),
 'details',case when payload->>'caseType'='REPORT' then (select details from app_private.safety_reports where id=(payload->>'caseId')::uuid) else null end,
 'status',case when payload->>'caseType'='REPORT' then (select status from app_private.safety_reports where id=(payload->>'caseId')::uuid) when payload->>'caseType'='ATTENDANCE' and not exists(select 1 from app_private.attendance_records r join app_private.table_assignments a on a.id=r.assignment_id join app_private.intake_applications i on i.id=a.application_id where r.assignment_id=(payload->>'caseId')::uuid and r.review_status='NO_SHOW' and i.attendance_status='NO_SHOW') then 'CORRECTED' when payload->>'caseType'='CANCELLATION' and not exists(select 1 from app_private.intake_applications where id=(payload->>'caseId')::uuid and attendance_status='CANCELED_LATE') then 'CORRECTED' else 'REVIEW' end,
 'actions',coalesce((select jsonb_agg(jsonb_build_object('action',action,'reason',reason,'state',state,'at',occurred_at) order by id) from(select * from app_private.safety_actions where target_id=target order by id desc limit 50) h),'[]'::jsonb));
end $$;
create function app_private.operations_safety_review(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.safety_reviewer();target uuid;req uuid;hash text;prior app_private.safety_commands;a app_private.safety_accounts;act text;item record;begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>6 or not(payload ?& array['caseType','caseId','requestKey','revision','action','reason'])
 or coalesce(payload->>'caseType','') not in('REPORT','ATTENDANCE','CANCELLATION') or exists(select 1 from unnest(array['caseId','requestKey']) k where coalesce(payload->>k,'')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 or coalesce(payload->>'action','') not in('REVIEWED','DISMISS','WARN','RESTRICT','BAN','RESTORE') or jsonb_typeof(payload->'reason') is distinct from 'string' or length(btrim(payload->>'reason')) not between 5 and 500
 or jsonb_typeof(payload->'revision') is distinct from 'number' or coalesce(payload->>'revision','')!~'^[0-9]{1,9}$' then raise exception 'VALIDATION_ERROR';end if;
 req:=(payload->>'requestKey')::uuid;hash:=encode(sha256(convert_to((payload-'requestKey')::text,'UTF8')),'hex');act:=payload->>'action';
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 target:=app_private.safety_case_target(payload->>'caseType',(payload->>'caseId')::uuid);if target is null then raise exception 'FORBIDDEN';end if;
 select * into prior from app_private.safety_commands where actor_id=actor and request_key=req;
 if prior.actor_id is not null then if prior.input_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT';end if;return app_private.operations_safety_detail(jsonb_build_object('caseType',payload->>'caseType','caseId',payload->>'caseId'));end if;
 insert into app_private.safety_accounts(user_id) values(target) on conflict do nothing;
 select * into a from app_private.safety_accounts where user_id=target for update;
 if (app_private.operations_safety_detail(jsonb_build_object('caseType',payload->>'caseType','caseId',payload->>'caseId'))->>'status')='CORRECTED' and act not in('RESTORE','REVIEWED') then raise exception 'SAFETY_CONFLICT';end if;
 if act='DISMISS' and payload->>'caseType'<>'REPORT' then raise exception 'VALIDATION_ERROR';end if;
 if a.revision<>(payload->>'revision')::int then raise exception 'SAFETY_CONFLICT';end if;
 if (select role from app_private.member_accounts where user_id=target)='operator' and act in('RESTRICT','BAN','RESTORE') then raise exception 'FORBIDDEN';end if;
 if a.state='BANNED' and act='RESTRICT' then raise exception 'SAFETY_CONFLICT';end if;
 update app_private.safety_accounts set revision=revision+1,state=case when act='BAN' then 'BANNED' when act='RESTRICT' then 'RESTRICTED' when act='RESTORE' then 'ACTIVE' when act='WARN' and state='ACTIVE' then 'WARNING' else state end where user_id=target returning * into a;
 if payload->>'caseType'='REPORT' then update app_private.safety_reports set status=case when act='DISMISS' then 'DISMISSED' else 'REVIEWED' end where id=(payload->>'caseId')::uuid;end if;
 perform app_private.safety_repair(req);
 if act='RESTORE' then
  for item in select i.id,e.id slot_id from app_private.intake_applications i join app_private.intake_event_slots e on i.input->'slotIds' ? e.id::text
  where i.user_id=target and i.application_status='SUBMITTED' and i.payment_status='PAID' and i.resolution_reason='safety_hold' and i.matching_status='ALTERNATIVE_OFFERED'
  and e.published and e.starts_at>clock_timestamp() and app_private.match_financially_eligible(i) order by i.id,e.id loop
   update app_private.intake_applications set matching_status='REALLOCATING',resolution_reason=null where id=item.id;
   insert into app_private.match_jobs(job_key,slot_id,due_at) values('safety-restore:'||req||':'||item.id||':'||item.slot_id,item.slot_id,greatest(clock_timestamp(),(select matches_at from app_private.intake_event_slots where id=item.slot_id))) on conflict do nothing;
  end loop;
 end if;
 insert into app_private.safety_actions(actor_id,target_id,case_type,case_id,action,reason,revision,state) values(actor,target,payload->>'caseType',(payload->>'caseId')::uuid,act,btrim(payload->>'reason'),a.revision,a.state);
 insert into app_private.safety_commands(actor_id,request_key,input_hash,kind) values(actor,req,hash,'REVIEW');
 insert into app_private.member_audit(actor_id,action) values(actor,'SAFETY_REVIEW_'||act);
 return app_private.operations_safety_detail(jsonb_build_object('caseType',payload->>'caseType','caseId',payload->>'caseId'));
end $$;
revoke all on function app_private.safety_allowed(uuid),app_private.safety_pair_blocked(uuid,uuid),app_private.safety_participation_guard(),app_private.safety_application_fence(),app_private.safety_repair(uuid),app_private.safety_reviewer(),app_private.safety_case_target(text,uuid),app_private.safety_get(),app_private.safety_submit(jsonb),app_private.operations_safety_get(),app_private.operations_safety_detail(jsonb),app_private.operations_safety_review(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.safety_get(),app_private.safety_submit(jsonb),app_private.operations_safety_get(),app_private.operations_safety_detail(jsonb),app_private.operations_safety_review(jsonb) to app_member_api;

-- Preserve money/retries while the participant is held; never auto-refund or extend.
create or replace function app_private.match_resolve(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype;
 previous app_private.match_resolutions%rowtype; legacy app_private.refund_attempts%rowtype; e app_private.intake_event_slots%rowtype; p app_private.payment_attempts%rowtype;
 action text:=payload->>'action'; key uuid; child uuid; result jsonb; failure boolean; cutoff timestamptz; confirmed_start timestamptz;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['applicationId','requestKey','action']
 or coalesce(action,'') not in ('transfer','store','refund','cancel')
 or (select count(*) from jsonb_object_keys(payload))<>(case when action in ('transfer','refund') then 4 else 3 end)
 or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or coalesce(payload->>'applicationId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or (action='transfer' and (not payload ? 'slotId' or jsonb_typeof(payload->'slotId') is distinct from 'string'))
 or (action='refund' and (not payload ? 'outcome' or coalesce(payload->>'outcome','') not in ('success','failure'))) then raise exception 'VALIDATION_ERROR'; end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into a from app_private.intake_applications where id=(payload->>'applicationId')::uuid and user_id=actor for update;
 if a.id is null then raise exception 'FORBIDDEN'; end if;
 select * into previous from app_private.match_resolutions where user_id=actor and request_key=key;
 if previous.id is not null then
  if previous.input<>payload then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return previous.result;
 end if;
 select * into legacy from app_private.refund_attempts where user_id=actor and request_key=key;
 if legacy.id is not null then
  if action<>'refund' or legacy.application_id<>a.id or legacy.outcome<>payload->>'outcome' then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  result:=jsonb_build_object('applicationId',a.id,'action',action,'newApplicationId',null);
  insert into app_private.match_resolutions(user_id,application_id,request_key,action,input,result) values(actor,a.id,key,action,payload,result);
  return result;
 end if;
 failure:=a.matching_status in ('ALTERNATIVE_OFFERED','NO_MATCH') and coalesce(a.resolution_reason,'matching_failure') in('matching_failure','safety_hold');
 if a.matching_status='TRANSFERRED' then raise exception 'RESOLUTION_CONFLICT'; end if;
 if a.payment_status not in ('PAID','REFUND_FAILED') then raise exception 'PAYMENT_CONFLICT'; end if;
 if a.membership_id is not null then perform 1 from app_private.memberships where id=a.membership_id for update; end if;
 select * into p from app_private.payment_attempts where id=a.credit_payment_id and user_id=actor and outcome='success' for update;
 if p.id is not null and exists(select 1 from app_private.refund_attempts where payment_id=p.id and outcome='success') then raise exception 'PAYMENT_CONFLICT'; end if;
 perform 1 from app_private.intake_event_slots where a.input->'slotIds' ? id::text order by id for share;
 select min(coalesce(refund_cutoff_at,app_private.refund_cutoff(starts_at))) into cutoff from app_private.intake_event_slots where a.input->'slotIds' ? id::text;
 select s.starts_at into confirmed_start from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id where ta.application_id=a.id and ta.active;
 if action='transfer' and not app_private.safety_allowed(actor) then raise exception 'PARTICIPATION_RESTRICTED';end if;
 if action in ('transfer','store') then
  if not failure or a.payment_status<>'PAID' or not(a.application_status='SUBMITTED' or a.credit_stored) then raise exception 'RESOLUTION_CONFLICT'; end if;
  if action='store' then
   if a.credit_stored then raise exception 'RESOLUTION_CONFLICT'; end if;
   update app_private.intake_applications set application_status='CANCELED',matching_status='NO_MATCH',credit_stored=true,resolution_reason=case when a.resolution_reason='safety_hold' then 'safety_hold' else 'matching_failure' end where id=a.id;
  else
   select * into e from app_private.intake_event_slots where id::text=payload->>'slotId' for share;
   if e.id is null or not e.published or e.opens_at>clock_timestamp() or e.closes_at<=clock_timestamp() or e.matches_at is null or e.matches_at<=clock_timestamp() or e.starts_at<=clock_timestamp() then raise exception 'EVENT_CLOSED'; end if;
   if exists(select 1 from app_private.consent_documents d where d.active and d.required and not exists(select 1 from app_private.member_consents c where c.user_id=actor and c.document_id=d.id))
   or (select count(distinct kind) from app_private.consent_documents where active and required)<2 then raise exception 'CONSENT_REQUIRED'; end if;
   if a.membership_id is not null and not app_private.membership_covers(a.membership_id,jsonb_build_array(e.id)) then raise exception 'MEMBERSHIP_REQUIRED'; end if;
   if a.membership_id is null and p.id is null then raise exception 'PAYMENT_CONFLICT'; end if;
   if exists(select 1 from app_private.intake_applications x where x.user_id=actor and x.id<>a.id and x.application_status='SUBMITTED' and x.input->'slotIds' ? e.id::text)
   or exists(select 1 from app_private.table_assignments ta where ta.user_id=actor and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+interval '3 hours','[)')) then raise exception 'DUPLICATE_APPLICATION'; end if;
   if exists(select 1 from app_private.intake_applications where user_id=actor and request_key=key) then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
   child:=gen_random_uuid();
   update app_private.intake_applications set application_status='CANCELED',matching_status='TRANSFERRED',credit_stored=false where id=a.id;
   insert into app_private.intake_applications(id,user_id,request_key,source_id,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status,membership_id,credit_payment_id)
   values(child,actor,key,a.id,a.input||jsonb_build_object('slotIds',jsonb_build_array(e.id),'regions',jsonb_build_array(e.region_code),'otherRegion',''),a.identity_snapshot,a.onboarding_snapshot,a.schema_version,
    (select jsonb_agg(jsonb_build_object('id',d.id,'version',d.version,'kind',d.kind)) from app_private.consent_documents d where d.active and d.required),a.product_snapshot,'PAID',a.membership_id,p.id);
   insert into app_private.match_jobs(job_key,slot_id,due_at) values('transfer:'||child,e.id,e.matches_at);
  end if;
 elsif action='cancel' then
  if a.application_status<>'SUBMITTED' or a.payment_status<>'PAID' or a.matching_status not in ('WAITING','REALLOCATING','CONFIRMED') then raise exception 'RESOLUTION_CONFLICT'; end if;
  if coalesce(confirmed_start,(select min(starts_at) from app_private.intake_event_slots where a.input->'slotIds' ? id::text))<=clock_timestamp() then raise exception 'CANCELLATION_CLOSED'; end if;
  update app_private.intake_applications set application_status='CANCELED',matching_status='NO_MATCH',attendance_status=case when clock_timestamp()<cutoff then 'CANCELED_EARLY' else 'CANCELED_LATE' end,
   resolution_reason=case when clock_timestamp()<cutoff then 'voluntary' else 'voluntary_late' end where id=a.id;
  perform app_private.cancel_table_repair(a.id,key);
 else
  if p.id is null then raise exception 'PAYMENT_CONFLICT'; end if;
  if a.resolution_reason='voluntary_late' then raise exception 'REFUND_CLOSED'; end if;
  if not failure and a.resolution_reason is distinct from 'voluntary' then
   if a.application_status<>'SUBMITTED' or a.matching_status<>'WAITING' then raise exception 'PAYMENT_CONFLICT'; end if;
   if a.payment_status='PAID' and clock_timestamp()>=cutoff then raise exception 'REFUND_CLOSED'; end if;
  end if;
  if a.membership_id is not null and exists(select 1 from app_private.intake_applications x where x.membership_id=a.membership_id and x.id<>a.id) then raise exception 'MEMBERSHIP_IN_USE'; end if;
  insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason)
  values(actor,a.id,p.id,key,p.amount_krw,payload->>'outcome',case when a.resolution_reason='safety_hold' then 'safety_hold' when failure then 'matching_failure' else 'voluntary' end);
  update app_private.intake_applications set payment_status=case when payload->>'outcome'='success' then 'REFUNDED' else 'REFUND_FAILED' end,
   application_status=case when payload->>'outcome'='success' then 'CANCELED' else application_status end,credit_stored=false where id=a.id;
  if a.membership_id is not null then update app_private.memberships set active=false where id=a.membership_id; end if;
 end if;
 result:=jsonb_build_object('applicationId',a.id,'action',action,'newApplicationId',child);
 insert into app_private.match_resolutions(user_id,application_id,request_key,action,input,result) values(actor,a.id,key,action,payload,result);
 insert into app_private.member_audit(actor_id,action) values(actor,'RESOLUTION_'||upper(action)||case when action='refund' then '_'||upper(payload->>'outcome') else '' end);
 return result;
end $$;


create or replace function app_private.mock_payment(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype; previous app_private.payment_attempts%rowtype;
 months int; expiry timestamptz; member_id uuid; key uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['applicationId','requestKey','outcome'] or (select count(*) from jsonb_object_keys(payload))<>3
  or coalesce(payload->>'outcome','') not in ('success','failure') or jsonb_typeof(payload->'outcome') is distinct from 'string'
  or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(payload->>'applicationId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION_ERROR'; end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into a from app_private.intake_applications where id::text=payload->>'applicationId' and user_id=actor for update;
 if a.id is null then raise exception 'FORBIDDEN'; end if;
 select * into previous from app_private.payment_attempts where user_id=actor and request_key=key;
 if previous.id is not null then
  if previous.application_id<>a.id or previous.outcome<>payload->>'outcome' then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return app_private.intake_get();
 end if;
 if not app_private.safety_allowed(actor) then raise exception 'PARTICIPATION_RESTRICTED';end if;
 if a.application_status<>'SUBMITTED' or a.payment_status not in ('PENDING','FAILED') or a.matching_status<>'WAITING' then raise exception 'PAYMENT_CONFLICT'; end if;
 if a.product_snapshot->>'policyVersion' is distinct from 'faq-v1' or a.product_snapshot->>'kind' not in ('single','membership') then raise exception 'TICKET_UNAVAILABLE'; end if;
 perform 1 from app_private.intake_event_slots where id::text in (select jsonb_array_elements_text(a.input->'slotIds')) order by id for share;
 if exists(select 1 from jsonb_array_elements_text(a.input->'slotIds') s where not exists(select 1 from app_private.intake_event_slots e where e.id::text=s and e.published and e.closes_at>now() and e.starts_at>now())) then raise exception 'EVENT_CLOSED'; end if;
 if payload->>'outcome'='success' and a.product_snapshot->>'kind'='membership' then
  if exists(select 1 from app_private.memberships where user_id=actor and active and ends_at>now()) then raise exception 'MEMBERSHIP_ACTIVE'; end if;
  months:=(a.product_snapshot->>'validityMonths')::int;
  expiry:=((now() at time zone 'Asia/Seoul')+make_interval(months=>months)) at time zone 'Asia/Seoul';
  if exists(select 1 from app_private.intake_event_slots e where a.input->'slotIds' ? e.id::text and e.starts_at>=expiry) then raise exception 'MEMBERSHIP_REQUIRED'; end if;
  insert into app_private.memberships(user_id,starts_at,ends_at,product_code) values(actor,now(),expiry,a.product_snapshot->>'code') returning id into member_id;
 end if;
 insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values(actor,a.id,key,payload->>'outcome',(a.product_snapshot->>'amountKrw')::int);
 update app_private.intake_applications set payment_status=case when payload->>'outcome'='success' then 'PAID' else 'FAILED' end,membership_id=member_id where id=a.id;
 insert into app_private.member_audit(actor_id,action) values(actor,case when payload->>'outcome'='success' then 'MOCK_PAYMENT_SUCCEEDED' else 'MOCK_PAYMENT_FAILED' end);
 return app_private.intake_get();
end $$;

create or replace function app_private.intake_submit(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); draft app_private.intake_drafts%rowtype; product app_private.intake_ticket_products%rowtype;
 membership uuid; app uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('intake-publication',0));
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 -- Existing request keys retain their immutable snapshot and idempotent result.
 if exists(select 1 from app_private.intake_applications where user_id=actor and request_key::text=payload->>'requestKey') then
  perform app_private.intake_submit_v1(payload); return app_private.intake_get();
 end if;
 if not app_private.safety_allowed(actor) then raise exception 'PARTICIPATION_RESTRICTED';end if;
 select * into draft from app_private.intake_drafts where user_id=actor for update;
 select * into product from app_private.intake_ticket_products where code=draft.input->>'ticketCode' and active for share;
 if product.code is null then raise exception 'TICKET_UNAVAILABLE'; end if;
 if product.kind='membership_use' then
  select m.id into membership from app_private.memberships m where m.user_id=actor and app_private.membership_covers(m.id,draft.input->'slotIds') order by m.ends_at desc limit 1 for update;
  if membership is null then raise exception 'MEMBERSHIP_REQUIRED'; end if;
 end if;
 perform app_private.intake_submit_v1(payload);
 select id into app from app_private.intake_applications where user_id=actor and request_key::text=payload->>'requestKey';
 update app_private.intake_applications set product_snapshot=product_snapshot || jsonb_build_object('kind',product.kind,'policyVersion',product.policy_version),
 membership_id=membership,payment_status=case when membership is null then 'PENDING' else 'PAID' end where id=app;
 return app_private.intake_get();
end $$;

alter function app_private.matching_get() rename to matching_get_v4;
revoke all on function app_private.matching_get_v4() from app_member_api;
create function app_private.matching_get() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();dto jsonb;allowed boolean:=app_private.safety_allowed(actor);begin
 dto:=app_private.matching_get_v4();
 return jsonb_build_object('applications',coalesce((select jsonb_agg(item||jsonb_build_object(
 'canResolve',case when a.resolution_reason='safety_hold' then a.payment_status='PAID' and a.matching_status in('ALTERNATIVE_OFFERED','NO_MATCH') and (a.application_status='SUBMITTED' or a.credit_stored) else (item->>'canResolve')::boolean end,
 'alternatives',case when allowed then item->'alternatives' else '[]'::jsonb end,
 'table',case when item->'table'='null'::jsonb then 'null'::jsonb when not allowed or exists(select 1 from app_private.table_assignments x join app_private.table_assignments y on y.table_id=x.table_id and x.id<y.id where x.table_id::text=item->'table'->>'id' and x.active and y.active and app_private.safety_pair_blocked(x.user_id,y.user_id)) then (item->'table')||jsonb_build_object('chat',null) else item->'table' end
 ) order by ordinal) from jsonb_array_elements(dto->'applications') with ordinality j(item,ordinal) join app_private.intake_applications a on a.id::text=item->>'id'),'[]'::jsonb));
end $$;
revoke all on function app_private.matching_get() from public,anon,authenticated;
grant execute on function app_private.matching_get() to app_member_api;
