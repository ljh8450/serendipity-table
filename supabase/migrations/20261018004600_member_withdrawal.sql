-- PRIV-002: independent soft-deletion state avoids account-row/matching-fence deadlocks.
create table app_private.privacy_policy(
 version text primary key,active boolean not null default false,financial interval not null,safety interval not null,audit interval not null,
 check(financial>interval '0' and safety>interval '0' and audit>interval '0'));
create unique index privacy_policy_active on app_private.privacy_policy(active) where active;
insert into app_private.privacy_policy values('privacy-v1',true,interval '5 years',interval '3 years',interval '1 year');
create table app_private.member_withdrawals(
 user_id uuid primary key,receipt_id uuid not null default gen_random_uuid() unique,request_key uuid not null,policy_version text not null references app_private.privacy_policy(version),
 withdrawn_at timestamptz not null default clock_timestamp(),personal_purged_at timestamptz,
 financial_until timestamptz not null,safety_until timestamptz not null,audit_until timestamptz not null,hard_deleted_at timestamptz);
create table app_private.privacy_holds(
 id uuid primary key default gen_random_uuid(),user_id uuid not null,kind text not null check(kind in('FINANCIAL','SAFETY','LEGAL')),
 reason text not null check(length(btrim(reason)) between 5 and 500),expires_at timestamptz not null,created_at timestamptz not null default clock_timestamp(),check(expires_at>created_at));
create table app_private.privacy_auth_jobs(
 id uuid primary key default gen_random_uuid(),user_id uuid not null references app_private.member_withdrawals(user_id) on delete cascade,kind text not null check(kind in('SOFT_DELETE','HARD_DELETE')),
 status text not null default 'PENDING' check(status in('PENDING','RUNNING','DONE','EXCEPTION')),
 due_at timestamptz not null default clock_timestamp(),attempts int not null default 0,token uuid,lease_until timestamptz,last_error text,finished_at timestamptz,
 unique(user_id,kind));
do $$ declare n text;begin foreach n in array array['privacy_policy','member_withdrawals','privacy_holds','privacy_auth_jobs'] loop
 execute format('alter table app_private.%I enable row level security',n);execute format('revoke all on app_private.%I from public,anon,authenticated,app_member_api',n);end loop;end $$;

create or replace function app_private.member_actor() returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;is_restricted boolean;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor) then raise exception 'UNAUTHENTICATED' using errcode='28000';end if;
 if exists(select 1 from app_private.member_withdrawals where user_id=actor) then raise exception 'FORBIDDEN' using errcode='42501';end if;
 insert into app_private.member_accounts(user_id) values(actor) on conflict do nothing;
 select restricted into is_restricted from app_private.member_accounts where user_id=actor for share;
 if is_restricted then raise exception 'FORBIDDEN' using errcode='42501';end if;return actor;
end $$;
create or replace function app_private.safety_allowed(u uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.member_accounts where user_id=u and not restricted
 and not exists(select 1 from app_private.member_withdrawals where user_id=u)
 and coalesce((select state from app_private.safety_accounts s where s.user_id=u),'ACTIVE') in('ACTIVE','WARNING'))
$$;

create or replace function app_private.safety_participation_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if current_setting('app.privacy_cleanup',true)='on' and exists(select 1 from app_private.member_withdrawals where user_id=new.user_id) then return new;end if;
 if new.application_status='SUBMITTED' and not app_private.safety_allowed(new.user_id) and (
 tg_op='INSERT' or old.application_status is distinct from new.application_status or old.user_id is distinct from new.user_id
 or old.input is distinct from new.input or (new.payment_status='PAID' and old.payment_status is distinct from new.payment_status)
 or (new.matching_status in('WAITING','REALLOCATING','CONFIRMED') and old.matching_status is distinct from new.matching_status)) then raise exception 'PARTICIPATION_RESTRICTED';end if;
 return new;
end $$;

create function app_private.privacy_actor() returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=nullif(current_setting('app.actor_id',true),'')::uuid;begin
 if actor is null or not exists(select 1 from auth.users where id=actor) then raise exception 'UNAUTHENTICATED';end if;return actor;end $$;
create or replace function app_private.privacy_get() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.privacy_actor();w app_private.member_withdrawals;p app_private.privacy_policy;begin
 select * into w from app_private.member_withdrawals where user_id=actor;select * into p from app_private.privacy_policy where active;
 return jsonb_build_object('withdrawn',w.user_id is not null,'receiptId',w.receipt_id,'withdrawnAt',w.withdrawn_at,'policyVersion',coalesce(w.policy_version,p.version),
 'canWithdraw',exists(select 1 from app_private.member_accounts where user_id=actor and role='participant') and w.user_id is null,
 'financialUntil',w.financial_until,'safetyUntil',w.safety_until,'auditUntil',w.audit_until,
 'authCleanupPending',exists(select 1 from app_private.privacy_auth_jobs where user_id=actor and kind='SOFT_DELETE' and status<>'DONE'),
 'unresolvedFinancialApplications',(select count(*) from app_private.intake_applications a where a.user_id=actor and (a.payment_status in('REFUND_FAILED','REFUND_PROCESSING','REFUND_REQUESTED') or (a.payment_status='PAID' and (a.credit_stored or a.matching_status in('WAITING','REALLOCATING','ALTERNATIVE_OFFERED','NO_MATCH','EXCEPTION'))))));
end $$;

-- Writes that began before withdrawal must recheck after the same matching fence.
create function app_private.privacy_personal_fence() returns trigger language plpgsql security definer set search_path='' as $$
begin perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));return null;end $$;
create function app_private.privacy_personal_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if current_setting('app.privacy_cleanup',true) is distinct from 'on' and exists(select 1 from app_private.member_withdrawals where user_id=new.user_id) then raise exception 'FORBIDDEN';end if;return new;end $$;
do $$ declare n text;begin foreach n in array array['member_profiles','intake_members','intake_drafts'] loop
 execute format('create trigger privacy_fence before insert or update on app_private.%I for each statement execute function app_private.privacy_personal_fence()',n);
 execute format('create trigger privacy_guard before insert or update on app_private.%I for each row execute function app_private.privacy_personal_guard()',n);end loop;end $$;
create trigger privacy_account_guard after update of username,display_name on app_private.member_accounts for each row execute function app_private.privacy_personal_guard();

create or replace function app_private.privacy_withdraw(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.privacy_actor();p app_private.privacy_policy;w app_private.member_withdrawals;key uuid;app record;t record;previous_cleanup text:=current_setting('app.privacy_cleanup',true);
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-array['requestKey','confirmation'])<>'{}'::jsonb
 or payload->>'confirmation' is distinct from '탈퇴' or coalesce(payload->>'requestKey','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'VALIDATION_ERROR';end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 select * into w from app_private.member_withdrawals where user_id=actor;
 if w.user_id is not null then if w.request_key<>key then raise exception 'IDEMPOTENCY_CONFLICT';end if;return app_private.privacy_get();end if;
 if not exists(select 1 from app_private.member_accounts where user_id=actor and role='participant') then raise exception 'FORBIDDEN';end if;
 select * into p from app_private.privacy_policy where active for share;if p.version is null then raise exception 'PRIVACY_NOT_CONFIGURED';end if;
 insert into app_private.member_withdrawals(user_id,request_key,policy_version,financial_until,safety_until,audit_until)
 values(actor,key,p.version,clock_timestamp()+case when exists(select 1 from app_private.payment_attempts where user_id=actor) or exists(select 1 from app_private.memberships where user_id=actor) then p.financial else interval '0' end,clock_timestamp()+case when exists(select 1 from app_private.safety_reports where reporter_id=actor or target_id=actor) or exists(select 1 from app_private.safety_actions where actor_id=actor or target_id=actor) then p.safety else interval '0' end,clock_timestamp()+p.audit);
 -- Only future tables are revalidated. Ongoing/past attendance evidence is retained.
 for app in select a.id from app_private.intake_applications a join app_private.table_assignments ta on ta.application_id=a.id and ta.active
 join app_private.dining_tables dt on dt.id=ta.table_id join app_private.intake_event_slots s on s.id=dt.slot_id
 where a.user_id=actor and s.starts_at>clock_timestamp() order by a.id loop
  perform app_private.cancel_table_repair(app.id,md5(key::text||app.id::text)::uuid);
 end loop;
 for t in select distinct dt.id,dt.slot_id from app_private.table_assignments a join app_private.dining_tables dt on dt.id=a.table_id
 join app_private.intake_event_slots s on s.id=dt.slot_id where a.user_id=actor and a.active and s.starts_at<=clock_timestamp() and s.starts_at+interval '3 hours'>clock_timestamp() loop
  insert into app_private.match_jobs(job_key,slot_id,due_at,status,last_error) values('withdrawal:'||key||':'||t.id,t.slot_id,clock_timestamp(),'EXCEPTION','WITHDRAWAL_DURING_EVENT') on conflict do nothing;
 end loop;
 update app_private.intake_applications a set application_status='CANCELED',matching_status='NO_MATCH',attendance_status='CANCELED_EARLY'
 where a.user_id=actor and not exists(select 1 from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id join app_private.intake_event_slots s on s.id=dt.slot_id where ta.application_id=a.id and s.starts_at<=clock_timestamp());
 delete from app_private.push_subscriptions where user_id=actor;
 delete from app_private.member_notifications where user_id=actor;
 update app_private.chat_members set active=false where user_id=actor;
 update app_private.chat_messages set body='탈퇴한 참가자의 메시지' where member_id in(select id from app_private.chat_members where user_id=actor) and kind='MEMBER';
 delete from app_private.member_profiles where user_id=actor;
 delete from app_private.intake_members where user_id=actor;
 delete from app_private.intake_drafts where user_id=actor;
 delete from app_private.intake_starts where user_id=actor;
 delete from app_private.person_preferences where user_id=actor or target_user_id=actor;
 delete from app_private.preference_commands where user_id=actor or peer_id in(select id from app_private.table_assignments where user_id=actor);
 perform set_config('app.privacy_cleanup','on',true);
 update app_private.intake_applications set identity_snapshot='{}',onboarding_snapshot='{}',input=jsonb_set(input,'{otherRegion}','""') where user_id=actor;
 update app_private.match_runs r set input_snapshot=(select coalesce(jsonb_agg(case when x->>'user_id'=actor::text or x->>'userId'=actor::text or x->>'applicationId' in(select id::text from app_private.intake_applications where user_id=actor) then jsonb_set(jsonb_set(x,'{profile}','{}'),'{input}','{}') else x end),'[]'::jsonb) from jsonb_array_elements(r.input_snapshot)x)
 where exists(select 1 from jsonb_array_elements(r.input_snapshot)x where x->>'user_id'=actor::text or x->>'userId'=actor::text or x->>'applicationId' in(select id::text from app_private.intake_applications where user_id=actor));
 perform set_config('app.privacy_cleanup',coalesce(previous_cleanup,''),true);
 update app_private.member_withdrawals set personal_purged_at=clock_timestamp() where user_id=actor;
 insert into app_private.privacy_auth_jobs(user_id,kind) values(actor,'SOFT_DELETE') on conflict do nothing;
 insert into app_private.member_audit(actor_id,action) values(actor,'MEMBER_WITHDRAWN');return app_private.privacy_get();
end $$;

-- Keep public operational labels anonymous immediately without locking member_accounts.
create function app_private.privacy_label(user_uuid uuid,label text) returns text language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from app_private.member_withdrawals where user_id=user_uuid) then '탈퇴한 회원' else label end
$$;
revoke all on function app_private.privacy_actor(),app_private.privacy_get(),app_private.privacy_withdraw(jsonb),app_private.privacy_personal_fence(),app_private.privacy_personal_guard(),app_private.privacy_label(uuid,text) from public,anon,authenticated,app_member_api;
grant execute on function app_private.privacy_get(),app_private.privacy_withdraw(jsonb) to app_member_api;

create or replace view app_private.operations_entities as
select 'members'::text kind,m.user_id id,app_private.privacy_label(m.user_id,coalesce(m.username,'회원')) label,
 case when exists(select 1 from app_private.member_withdrawals where user_id=m.user_id) then 'WITHDRAWN' when m.restricted then 'RESTRICTED' else 'ACTIVE' end status,
 m.user_id member_id,null::uuid slot_id,null::uuid table_id,null::uuid application_id,
 null::timestamptz at,
 jsonb_build_object('role',m.role) facts
from app_private.member_accounts m
union all
select 'applications',a.id,app_private.privacy_label(m.user_id,coalesce(m.username,'회원')),a.application_status,a.user_id,null,ta.table_id,a.id,a.submitted_at,
 jsonb_build_object('applicationStatus',a.application_status,'paymentStatus',a.payment_status,
 'matchingStatus',a.matching_status,'attendanceStatus',a.attendance_status,
 'selectedSlotIds',a.input->'slotIds','selectedRegions',a.input->'regions')
from app_private.intake_applications a left join app_private.member_accounts m on m.user_id=a.user_id
left join app_private.table_assignments ta on ta.application_id=a.id and ta.active
union all
select 'slots',s.id,s.region_label,case when s.published then 'PUBLISHED' else 'DRAFT' end,null,s.id,null,null,s.starts_at,
 jsonb_build_object('closesAt',s.closes_at,'matchesAt',s.matches_at,'capacity',s.capacity,
 'tableCount',(select count(*) from app_private.dining_tables t where t.slot_id=s.id),
 'selectedApplicationCount',(select count(*) from app_private.intake_applications a where a.input->'slotIds' ? s.id::text))
from app_private.intake_event_slots s
union all
select 'tables',t.id,s.region_label,t.status,null,t.slot_id,t.id,null,s.starts_at,
 jsonb_build_object('activeCount',(select count(*) from app_private.table_assignments a where a.table_id=t.id and a.active),
 'venueName',(select v.name from app_private.venue_allocations a join app_private.venue_inventory v on v.id=a.inventory_id where a.table_id=t.id and a.active),
 'roomStatus',(select r.status from app_private.chat_rooms r where r.table_id=t.id))
from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id
union all
select 'exceptions',j.id,'매칭 작업','EXCEPTION',null,j.slot_id,null,null,j.due_at,
 jsonb_build_object('domain','matching','attempts',j.attempts,'nextAction','매칭 모니터에서 현재 상태 확인 후 재시도')
from app_private.match_jobs j where j.status='EXCEPTION'
union all
select 'exceptions',r.event_id,'식당 배정','EXCEPTION',null,t.slot_id,t.id,null,r.due_at,
 jsonb_build_object('reason',case when r.last_error='VENUE_NO_COMPATIBLE_INVENTORY' then '적합한 식당 재고 없음' when r.last_error='VENUE_EVENT_STARTED' then '행사 시작으로 배정 종료' else '배정 작업 실패' end,'domain','venues','attempts',r.attempts,'nextAction','식당 재고와 적합성을 확인하고 식당 모니터에서 재시도')
from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id
join app_private.dining_tables t on t.id=o.aggregate_id where r.status='EXCEPTION'
union all
select 'exceptions',r.event_id,'단체방 생성','EXCEPTION',null,t.slot_id,t.id,null,r.due_at,
 jsonb_build_object('domain','chat','attempts',r.attempts,'nextAction','단체방 모니터에서 현재 배정 확인 후 재시도')
from app_private.chat_receipts r join app_private.match_outbox o on o.id=r.event_id
join app_private.dining_tables t on t.id=o.aggregate_id where r.status='EXCEPTION'
union all
select 'exceptions',j.id,'예약 안내','EXCEPTION',null,t.slot_id,t.id,null,j.due_at,
 jsonb_build_object('domain','content','attempts',j.attempts,'nextAction','예약 콘텐츠 모니터에서 장소와 기한 확인 후 재시도')
from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where j.status='EXCEPTION'
union all
select 'exceptions',j.id,'피드백 요청','EXCEPTION',a.user_id,t.slot_id,t.id,a.application_id,j.due_at,
 jsonb_build_object('domain','feedback','attempts',j.attempts,'nextAction','피드백 요청 모니터에서 참석과 기한 확인 후 재시도')
from app_private.feedback_jobs j join app_private.table_assignments a on a.id=j.assignment_id
join app_private.dining_tables t on t.id=a.table_id where j.status='EXCEPTION'
union all
select 'exceptions',j.id,'웹 푸시','EXCEPTION',n.user_id,t.slot_id,n.table_id,n.application_id,j.due_at,
 jsonb_build_object('domain','push','attempts',j.attempts,'nextAction','푸시 모니터에서 구독과 현재 참가 권한 확인 후 재시도')
from app_private.push_jobs j join app_private.member_notifications n on n.id=j.notification_id
left join app_private.dining_tables t on t.id=n.table_id where j.status='EXCEPTION';


revoke all on app_private.operations_entities from public,anon,authenticated,app_member_api;
