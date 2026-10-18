-- Retention and Auth work use server time and private roles only.
create role app_privacy_dispatch nologin;
grant app_privacy_dispatch to postgres;
grant usage on schema app_private to app_privacy_dispatch;
alter table app_private.member_withdrawals add column hard_delete_prepared_at timestamptz;
alter table app_private.member_withdrawals add column last_checked_at timestamptz;
alter table app_private.privacy_holds add constraint privacy_hold_finite check(isfinite(expires_at));
create index privacy_due_jobs on app_private.privacy_auth_jobs(status,due_at);
create index privacy_check_order on app_private.member_withdrawals(last_checked_at,withdrawn_at);
create index privacy_active_holds on app_private.privacy_holds(user_id,expires_at);
create function app_private.privacy_hold_fence() returns trigger language plpgsql security definer set search_path='' as $$
begin perform pg_advisory_xact_lock(hashtextextended('matching-state',0));return null;end $$;
create trigger privacy_hold_fence before insert or update or delete on app_private.privacy_holds for each statement execute function app_private.privacy_hold_fence();
create function app_private.privacy_hold_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from app_private.member_withdrawals where user_id=new.user_id and hard_delete_prepared_at is not null) then raise exception 'PRIVACY_ALREADY_FINALIZED';end if;
 return new;
end $$;
create trigger privacy_hold_guard before insert or update on app_private.privacy_holds for each row execute function app_private.privacy_hold_guard();

create function app_private.privacy_financial_hold(subject uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.intake_applications a where a.user_id=subject
 and (a.payment_status in('REFUND_FAILED','REFUND_PROCESSING','REFUND_REQUESTED') or (a.payment_status='PAID'
 and (a.credit_stored or a.matching_status in('WAITING','REALLOCATING','ALTERNATIVE_OFFERED','NO_MATCH','EXCEPTION')))))
 or exists(select 1 from app_private.memberships m where m.user_id=subject and m.active and m.ends_at>clock_timestamp())
$$;
create function app_private.privacy_retention_tick() returns int language plpgsql security definer set search_path='' as $$
declare w app_private.member_withdrawals;p app_private.privacy_policy;n int:=0;safety_deadline timestamptz;financial_deadline timestamptz;
begin
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 for w in select * from app_private.member_withdrawals where hard_deleted_at is null and hard_delete_prepared_at is null order by last_checked_at nulls first,withdrawn_at limit 50 for update skip locked loop
  update app_private.member_withdrawals set last_checked_at=clock_timestamp() where user_id=w.user_id;
  select * into p from app_private.privacy_policy where version=w.policy_version;
  select greatest(w.financial_until,coalesce((select max(created_at)+p.financial from app_private.payment_attempts where user_id=w.user_id),w.financial_until),coalesce((select max(created_at)+p.financial from app_private.refund_attempts where user_id=w.user_id),w.financial_until)) into financial_deadline;
  if financial_deadline>w.financial_until then update app_private.member_withdrawals set financial_until=financial_deadline where user_id=w.user_id;w.financial_until:=financial_deadline;end if;
  select greatest(w.safety_until,coalesce((select max(created_at)+p.safety from app_private.safety_reports where reporter_id=w.user_id or target_id=w.user_id),w.safety_until),
   coalesce((select max(occurred_at)+p.safety from app_private.safety_actions where actor_id=w.user_id or target_id=w.user_id),w.safety_until)) into safety_deadline;
  if safety_deadline>w.safety_until then update app_private.member_withdrawals set safety_until=safety_deadline where user_id=w.user_id;w.safety_until:=safety_deadline;end if;
  if exists(select 1 from app_private.privacy_holds where user_id=w.user_id and expires_at>clock_timestamp()) then continue;end if;
  if w.audit_until<=clock_timestamp() then
   delete from app_private.member_audit where actor_id=w.user_id and occurred_at<=clock_timestamp()-p.audit;
   delete from app_private.operations_exports where actor_id=w.user_id and exported_at<=clock_timestamp()-p.audit;
   delete from app_private.operations_interventions where actor_id=w.user_id and at<=clock_timestamp()-p.audit;
  end if;
  if w.safety_until<=clock_timestamp() then
   delete from app_private.safety_reports where (reporter_id=w.user_id or target_id=w.user_id) and created_at+p.safety<=clock_timestamp();
   delete from app_private.safety_actions where (actor_id=w.user_id or target_id=w.user_id) and occurred_at+p.safety<=clock_timestamp();
   delete from app_private.safety_commands where (actor_id=w.user_id or target_id=w.user_id) and created_at+p.safety<=clock_timestamp();
  end if;
  if greatest(w.financial_until,w.safety_until,w.audit_until)<=clock_timestamp() and not app_private.privacy_financial_hold(w.user_id)
  and not exists(select 1 from app_private.privacy_auth_jobs where user_id=w.user_id and kind='HARD_DELETE') then
   insert into app_private.privacy_auth_jobs(user_id,kind) values(w.user_id,'HARD_DELETE');n:=n+1;
  end if;
 end loop;
 delete from app_private.privacy_holds where expires_at<=clock_timestamp();
 -- Minimal deletion receipts expire a year after final Auth removal.
 delete from app_private.privacy_auth_jobs j using app_private.member_withdrawals expired where j.user_id=expired.user_id and expired.hard_deleted_at<clock_timestamp()-interval '1 year';
 delete from app_private.member_withdrawals where hard_deleted_at<clock_timestamp()-interval '1 year';
 return n;
end $$;

create function app_private.privacy_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare j app_private.privacy_auth_jobs;begin
 select * into j from app_private.privacy_auth_jobs where (status='PENDING' and due_at<=clock_timestamp()) or (status='RUNNING' and lease_until<=clock_timestamp())
 order by due_at,id limit 1 for update skip locked;
 if j.id is null then return null;end if;
 update app_private.privacy_auth_jobs set status='RUNNING',token=gen_random_uuid(),lease_until=clock_timestamp()+interval '1 minute',attempts=attempts+1 where id=j.id returning * into j;
 return jsonb_build_object('id',j.id,'userId',j.user_id,'kind',j.kind,'token',j.token);
end $$;
create function app_private.privacy_hard_prepare(job_id uuid,claim_token uuid) returns void language plpgsql security definer set search_path='' as $$
declare j app_private.privacy_auth_jobs;w app_private.member_withdrawals;begin
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 select * into j from app_private.privacy_auth_jobs where id=job_id and token=claim_token and status='RUNNING' and lease_until>clock_timestamp() for update;
 if j.id is null or j.kind<>'HARD_DELETE' then raise exception 'STALE_CLAIM';end if;
 select * into w from app_private.member_withdrawals where user_id=j.user_id for update;
 if w.user_id is null or greatest(w.financial_until,w.safety_until,w.audit_until)>clock_timestamp()
 or app_private.privacy_financial_hold(j.user_id) or exists(select 1 from app_private.privacy_holds where user_id=j.user_id and expires_at>clock_timestamp()) then raise exception 'RETENTION_HOLD';end if;
 if exists(select 1 from app_private.payment_attempts r join app_private.privacy_policy p on p.version=w.policy_version where r.user_id=j.user_id and r.created_at+p.financial>clock_timestamp())
 or exists(select 1 from app_private.refund_attempts r join app_private.privacy_policy p on p.version=w.policy_version where r.user_id=j.user_id and r.created_at+p.financial>clock_timestamp()) then raise exception 'RETENTION_HOLD';end if;
 if exists(select 1 from app_private.safety_reports r join app_private.privacy_policy p on p.version=w.policy_version where (r.reporter_id=j.user_id or r.target_id=j.user_id) and r.created_at+p.safety>clock_timestamp())
 or exists(select 1 from app_private.safety_actions a join app_private.privacy_policy p on p.version=w.policy_version where (a.actor_id=j.user_id or a.target_id=j.user_id) and a.occurred_at+p.safety>clock_timestamp()) then raise exception 'RETENTION_HOLD';end if;
 -- Finalization prevents a new legal hold from racing the external Auth deletion.
 update app_private.member_withdrawals set hard_delete_prepared_at=coalesce(hard_delete_prepared_at,clock_timestamp()) where user_id=j.user_id;
 update app_private.match_runs r set input_snapshot=(select coalesce(jsonb_agg(x),'[]'::jsonb) from jsonb_array_elements(r.input_snapshot)x where coalesce(x->>'userId',x->>'user_id','')<>j.user_id::text and coalesce(x->>'applicationId','') not in(select id::text from app_private.intake_applications where user_id=j.user_id))
 where exists(select 1 from jsonb_array_elements(r.input_snapshot)x where coalesce(x->>'userId',x->>'user_id','')=j.user_id::text or x->>'applicationId' in(select id::text from app_private.intake_applications where user_id=j.user_id));
 delete from app_private.safety_reports where reporter_id=j.user_id or target_id=j.user_id;
 delete from app_private.safety_actions where actor_id=j.user_id or target_id=j.user_id;
 delete from app_private.safety_commands where actor_id=j.user_id or target_id=j.user_id;
 delete from app_private.attendance_actions where actor_id=j.user_id or assignment_id in(select id from app_private.table_assignments where user_id=j.user_id);
 delete from app_private.attendance_records where assignment_id in(select id from app_private.table_assignments where user_id=j.user_id);
 delete from app_private.event_feedback where user_id=j.user_id;
 delete from app_private.feedback_jobs where assignment_id in(select id from app_private.table_assignments where user_id=j.user_id);
 delete from app_private.chat_members where user_id=j.user_id;
 delete from app_private.person_preferences where user_id=j.user_id or target_user_id=j.user_id;
 delete from app_private.preference_commands where user_id=j.user_id or peer_id in(select id from app_private.table_assignments where user_id=j.user_id) or assignment_id in(select id from app_private.table_assignments where user_id=j.user_id);
 delete from app_private.table_assignments where user_id=j.user_id;
 delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id=j.user_id);
 delete from app_private.membership_extensions where application_id in(select id from app_private.intake_applications where user_id=j.user_id);
 delete from app_private.refund_attempts where user_id=j.user_id;
 update app_private.intake_applications set credit_payment_id=null,membership_id=null where user_id=j.user_id;
 delete from app_private.payment_attempts where user_id=j.user_id;
 delete from app_private.match_resolutions where user_id=j.user_id;
 delete from app_private.intake_applications where user_id=j.user_id;
 delete from app_private.member_audit where actor_id=j.user_id;
 delete from app_private.operations_exports where actor_id=j.user_id;
 delete from app_private.operations_interventions where actor_id=j.user_id;
 delete from app_private.operations_work_sessions where actor_id=j.user_id;
end $$;
create function app_private.privacy_finish(job_id uuid,claim_token uuid,success boolean) returns void language plpgsql security definer set search_path='' as $$
declare j app_private.privacy_auth_jobs;begin
 select * into j from app_private.privacy_auth_jobs where id=job_id and token=claim_token and status='RUNNING' and lease_until>clock_timestamp() for update;
 if j.id is null then raise exception 'STALE_CLAIM';end if;
 if success then
  if j.kind='SOFT_DELETE' then
   perform set_config('app.privacy_cleanup','on',true);
   update app_private.member_accounts set username=null,display_name='탈퇴한 회원' where user_id=j.user_id;
  else update app_private.member_withdrawals set hard_deleted_at=clock_timestamp() where user_id=j.user_id;end if;
  update app_private.privacy_auth_jobs set status='DONE',finished_at=clock_timestamp(),last_error=null,lease_until=null where id=j.id;
 else
  update app_private.privacy_auth_jobs set status=case when attempts>=5 then 'EXCEPTION' else 'PENDING' end,
   due_at=clock_timestamp()+make_interval(mins=>least(60,attempts*2)),lease_until=null,last_error='AUTH_DELETE_FAILED' where id=j.id;
 end if;
end $$;

create function app_private.privacy_auth_complete(job_id uuid,claim_token uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.privacy_auth_jobs j where j.id=job_id and j.token=claim_token and j.status='RUNNING' and j.lease_until>clock_timestamp()
 and (not exists(select 1 from auth.users u where u.id=j.user_id) or (j.kind='SOFT_DELETE' and exists(select 1 from auth.users u where u.id=j.user_id and u.deleted_at is not null))))
$$;

create function app_private.operations_privacy_get() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();begin
 return jsonb_build_object('jobs',coalesce((select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'status',status,'attempts',attempts,'dueAt',due_at) order by due_at desc,id) from(select * from app_private.privacy_auth_jobs order by due_at desc,id limit 100)j),'[]'::jsonb),
 'retentionHeld',(select count(*) from app_private.member_withdrawals w where w.hard_deleted_at is null and greatest(w.financial_until,w.safety_until,w.audit_until)<=clock_timestamp() and (app_private.privacy_financial_hold(w.user_id) or exists(select 1 from app_private.privacy_holds where user_id=w.user_id and expires_at>clock_timestamp()))));end $$;
create function app_private.operations_privacy_retry(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();changed int;begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'jobId')<>'{}'::jsonb or coalesce(payload->>'jobId','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'VALIDATION_ERROR';end if;
 update app_private.privacy_auth_jobs set status='PENDING',attempts=0,token=null,lease_until=null,last_error=null,due_at=clock_timestamp()
 where id::text=payload->>'jobId' and status='EXCEPTION';get diagnostics changed=row_count;if changed<>1 then raise exception 'JOB_CONFLICT';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'PRIVACY_EXCEPTION_REQUEUED');return app_private.operations_privacy_get();end $$;

create function app_private.privacy_auth_dispatch_tick() returns bigint language plpgsql security definer set search_path='' as $$
declare endpoint text;secret text;request_id bigint;begin
 select decrypted_secret into endpoint from vault.decrypted_secrets where name='privacy_dispatch_url';
 select decrypted_secret into secret from vault.decrypted_secrets where name='privacy_dispatch_token';
 if endpoint is null or length(coalesce(secret,''))<32 then return null;end if;
 select net.http_post(url=>endpoint,headers=>jsonb_build_object('Authorization','Bearer '||secret,'Content-Type','application/json'),body=>'{}'::jsonb,timeout_milliseconds=>15000) into request_id;
 return request_id;
end $$;
select cron.schedule('serendipity-privacy-retention','17 * * * *','select app_private.privacy_retention_tick();');
select cron.schedule('serendipity-privacy-auth','* * * * *','select app_private.privacy_auth_dispatch_tick();');
revoke all on function app_private.privacy_hold_fence(),app_private.privacy_hold_guard(),app_private.privacy_financial_hold(uuid),app_private.privacy_retention_tick(),app_private.privacy_claim(),app_private.privacy_hard_prepare(uuid,uuid),app_private.privacy_finish(uuid,uuid,boolean),app_private.privacy_auth_complete(uuid,uuid),app_private.operations_privacy_get(),app_private.operations_privacy_retry(jsonb),app_private.privacy_auth_dispatch_tick() from public,anon,authenticated,app_member_api,app_privacy_dispatch;
grant execute on function app_private.privacy_claim(),app_private.privacy_hard_prepare(uuid,uuid),app_private.privacy_finish(uuid,uuid,boolean),app_private.privacy_auth_complete(uuid,uuid) to app_privacy_dispatch;
grant execute on function app_private.operations_privacy_get(),app_private.operations_privacy_retry(jsonb) to app_member_api;

-- Include privacy exception retries in the same measured intervention scope.
alter table app_private.operations_interventions add column subject_user_id uuid;
create or replace function app_private.operations_observe_audit() returns trigger language plpgsql security definer set search_path='' as $$
declare command text:=current_setting('app.operation_name',true);p jsonb;slot uuid;app uuid;tbl uuid;subject uuid;
begin
 if command is null or command not in('matching-retry','venue-retry','chat-retry','content-retry','push-retry','feedback-retry','attendance-review','safety-review','privacy-retry')
 or not exists(select 1 from app_private.member_accounts where user_id=new.actor_id and role='operator') then return new;end if;
 p:=current_setting('app.operation_payload',true)::jsonb;
 if command='privacy-retry' then select user_id into subject from app_private.privacy_auth_jobs where id::text=p->>'jobId';
 elsif command='matching-retry' then select slot_id into slot from app_private.match_jobs where id::text=p->>'jobId';
 elsif command in('venue-retry','chat-retry') then select aggregate_id into tbl from app_private.match_outbox where id::text=p->>'eventId';
 elsif command='content-retry' then select table_id into tbl from app_private.content_jobs where id::text=p->>'jobId';
 elsif command='feedback-retry' then select a.table_id,a.application_id into tbl,app from app_private.feedback_jobs j join app_private.table_assignments a on a.id=j.assignment_id where j.id::text=p->>'jobId';
 elsif command='push-retry' then select n.table_id,n.application_id into tbl,app from app_private.push_jobs j join app_private.member_notifications n on n.id=j.notification_id where j.id::text=p->>'jobId';
 elsif command='attendance-review' then select table_id,application_id into tbl,app from app_private.table_assignments where id::text=p->>'assignmentId';
 elsif command='safety-review' then
  if p->>'caseType'='REPORT' then select a.table_id into tbl from app_private.safety_reports r join app_private.table_assignments a on a.id=r.assignment_id where r.id::text=p->>'caseId';
  elsif p->>'caseType'='ATTENDANCE' then select table_id,application_id into tbl,app from app_private.table_assignments where id::text=p->>'caseId';
  else select a.table_id,a.application_id into tbl,app from app_private.table_assignments a where a.application_id::text=p->>'caseId' order by a.active desc,a.id limit 1;end if;
 end if;
 if tbl is not null then select slot_id into slot from app_private.dining_tables where id=tbl;end if;
 insert into app_private.operations_interventions(audit_id,actor_id,command,slot_id,application_id,subject_user_id) values(new.id,new.actor_id,command,slot,app,subject) on conflict do nothing;
 return new;
end $$;

create or replace function app_private.operations_metrics(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();from_at timestamptz;to_at timestamptz;slot uuid;since_at timestamptz;result jsonb;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-array['from','to','slotId'])<>'{}'::jsonb or not(payload ?& array['from','to'])
 or exists(select 1 from jsonb_each(payload)v where jsonb_typeof(v.value)<>'string') then raise exception 'VALIDATION_ERROR';end if;
 perform app_private.operations_explore(jsonb_build_object('kind','slots','from',payload->>'from','to',payload->>'to'));
 from_at:=(payload->>'from')::timestamptz;to_at:=(payload->>'to')::timestamptz;
 begin slot:=(payload->>'slotId')::uuid;exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 if slot is not null and not exists(select 1 from app_private.intake_event_slots where id=slot) then raise exception 'VALIDATION_ERROR';end if;
 select since into since_at from app_private.operations_measurement_config where id;
 with apps as(select * from app_private.intake_applications a where a.submitted_at>=from_at and a.submitted_at<to_at and (slot is null or a.input->'slotIds' ? slot::text)),
 paid as(select * from apps a where exists(select 1 from app_private.payment_attempts p where p.application_id=a.id and p.outcome='success') or a.membership_id is not null or a.credit_payment_id is not null),
 confirmed as(select distinct a.user_id,a.id from apps a join app_private.table_assignments ta on ta.application_id=a.id),
 live_confirmed as(select distinct a.user_id,a.id from paid a join app_private.table_assignments ta on ta.application_id=a.id and ta.active join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED'),
 attended as(select distinct a.user_id,a.id,ta.id assignment_id,s.starts_at from apps a join app_private.table_assignments ta on ta.application_id=a.id and ta.active join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED' join app_private.intake_event_slots s on s.id=t.slot_id where a.attendance_status='ATTENDED' and s.starts_at+interval '3 hours'<=clock_timestamp()),
 tables as(select * from app_private.dining_tables t where t.created_at>=from_at and t.created_at<to_at and t.status='CONFIRMED' and (slot is null or t.slot_id=slot)),
 failures as(select distinct a.id from apps a where exists(select 1 from app_private.allocation_attempts h where h.application_id=a.id and h.reason in('SOURCE_REPLANNED','REALLOCATED','ALTERNATIVE_OFFERED')) or exists(select 1 from app_private.table_assignments old join app_private.dining_tables dt on dt.id=old.table_id where old.application_id=a.id and dt.status='INVALIDATED')),
 alternatives as(select distinct a.id from apps a join app_private.allocation_attempts h on h.application_id=a.id where h.reason='ALTERNATIVE_OFFERED'),
 refunds as(select distinct a.id from apps a join app_private.refund_attempts r on r.application_id=a.id),
 starts as(select * from app_private.intake_starts s where started_at>=from_at and started_at<to_at and (slot is null or s.slot_ids ? slot::text)),
 interventions as(select * from app_private.operations_interventions i where i.at>=since_at),
 work as(select * from app_private.operations_work_sessions w where w.started_at>=from_at and w.started_at<to_at and (slot is null or w.slot_id=slot))
 select jsonb_build_object('from',from_at,'to',to_at,'asOf',clock_timestamp(),'instrumentationSince',since_at,
 'metrics',jsonb_build_array(
 app_private.operations_metric('applicationCompletion','신청 완료율',(select count(distinct s.user_id) from starts s where exists(select 1 from app_private.intake_applications a where a.user_id=s.user_id and a.request_key=s.request_key)),(select count(distinct user_id) from starts),'ratio','회차 신청 단계에 진입한 고유 사용자 중 같은 작성 키로 제출한 사용자. 시작 수집 이전은 미계측.',case when from_at<since_at then 'PARTIAL' else 'COMPLETE' end),
 app_private.operations_metric('paymentConversion','결제 전환율',(select count(distinct user_id) from paid),(select count(distinct user_id) from apps),'ratio','기간 내 제출한 고유 사용자 중 원결제/멤버십/이동 자격이 확인된 사용자.'),
 app_private.operations_metric('matchingSuccess','매칭 성공률',(select count(distinct user_id) from live_confirmed),(select count(distinct user_id) from paid),'ratio','결제 자격 사용자 중 현재 유효 확정 테이블이 있는 사용자. 취소·정정 반영.'),
 app_private.operations_metric('automaticConfirmation','자동 확정률',(select count(*) from tables t where t.created_at>=since_at and not exists(select 1 from interventions i where i.slot_id=t.slot_id and i.at<=t.created_at)),(select count(*) from tables where created_at>=since_at),'ratio','기간 내 생성된 현재 확정 테이블 중 생성 전 해당 회차 예외 개입이 없는 테이블. 수집 시작 이후만 측정.',case when exists(select 1 from tables where created_at<since_at) then 'PARTIAL' else 'COMPLETE' end),
 app_private.operations_metric('reallocationSuccess','자동 재배치 성공률',(select count(distinct f.id) from failures f join app_private.table_assignments ta on ta.application_id=f.id and ta.active join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED' where exists(select 1 from app_private.allocation_attempts h where h.application_id=f.id and h.step>0 and h.reason='REALLOCATED') or exists(select 1 from app_private.table_assignments old join app_private.dining_tables dt on dt.id=old.table_id where old.application_id=f.id and dt.status='INVALIDATED' and dt.id<>t.id)),(select count(*) from failures),'ratio','최초 실패/재계획/무효 테이블 이력이 있는 신청 중 다른 유효 테이블에 자동 배치된 신청. 선택 일정 이동 단계와 같은 회차의 무효 테이블 복구를 포함.'),
 app_private.operations_metric('alternativeConversion','대체 일정 전환율',(select count(distinct a.id) from alternatives a join app_private.match_resolutions r on r.application_id=a.id and r.action='transfer'),(select count(*) from alternatives),'ratio','최종 대안 제시 이력이 있는 신청 중 명시 이동을 완료한 신청. 재시도는 신청별 한 번.'),
 app_private.operations_metric('automaticRefund','자동 환불 완료율',(select count(*) from refunds a where exists(select 1 from app_private.refund_attempts r where r.application_id=a.id and r.outcome='success') and not exists(select 1 from interventions i where i.application_id=a.id and i.command like '%refund%')),(select count(*) from refunds),'ratio','환불 선택 신청 중 모의 환불 성공 신청. 현재 환불 API는 본인 선택 자동 처리이며 운영자 환불 명령은 없음. 실제 PG가 아님.'),
 app_private.operations_metric('attendanceConversion','실제 참가 전환율',(select count(distinct user_id) from attended),(select count(distinct user_id) from apps),'ratio','기간 내 신청 고유 사용자 중 종료 식탁 참석이 확인된 사용자. 미래 회차는 아직 미참석.'),
 app_private.operations_metric('noShow','노쇼율',(select count(distinct a.user_id) from apps a join app_private.table_assignments ta on ta.application_id=a.id join app_private.attendance_records r on r.assignment_id=ta.id where a.attendance_status='NO_SHOW' and r.review_status='NO_SHOW'),(select count(distinct user_id) from confirmed),'ratio','배정 이력이 있는 고유 사용자 중 현재 확인 노쇼 사용자. 미확정 후보는 제외.'),
 app_private.operations_metric('returnVisit','재방문율',(select count(distinct a.user_id) from attended a where exists(select 1 from app_private.intake_applications later where later.user_id=a.user_id and later.submitted_at>a.starts_at+interval '3 hours' and later.id<>a.id)),(select count(distinct user_id) from attended),'ratio','종료 참석 고유 사용자 중 행사 종료 후 다른 신청을 제출한 사용자. 후속 신청은 조회 현재까지 확인.'),
 app_private.operations_metric('feedbackResponse','피드백 응답률',(select count(distinct a.user_id) from attended a join app_private.event_feedback f on f.assignment_id=a.assignment_id),(select count(distinct user_id) from attended),'ratio','종료 참석 고유 사용자 중 일반 식탁 평가를 제출한 사용자. 참석 정정 시 다시 계산.'),
 app_private.operations_metric('operatorIntervention','운영자 개입률',(select count(distinct a.id) from apps a where a.submitted_at>=since_at and exists(select 1 from interventions i where i.subject_user_id=a.user_id or i.application_id=a.id or (i.slot_id is not null and (a.input->'slotIds' ? i.slot_id::text or exists(select 1 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id where ta.application_id=a.id and t.slot_id=i.slot_id))))),(select count(*) from apps where submitted_at>=since_at),'ratio','수집 시작 이후 신청 중 성공한 운영 예외 명령의 신청 또는 회차 범위에 속한 신청. 회차 작업은 영향 신청 전체에 연결. 반복 명령은 신청별 중복 제외.',case when from_at<since_at then 'PARTIAL' else 'COMPLETE' end),
 app_private.operations_metric('operatingTime','회차 운영 시간',(select sum(extract(epoch from(ended_at-started_at))) from work where ended_at is not null),(select count(distinct slot_id) from work where ended_at is not null),'secondsPerSlot','서버 시작/종료로 기록한 완료 세션의 초 합계 ÷ 실제 측정된 회차 수. 미종료/미계측 시간은 0으로 추정하지 않음.',case when not exists(select 1 from work where ended_at is not null) then 'UNMEASURED' else 'PARTIAL' end)),
 'openSessions',(select count(*) from work where ended_at is null),'completedSessions',(select count(*) from work where ended_at is not null),
 'myActiveSession',(select jsonb_build_object('id',id,'slotId',slot_id,'startedAt',started_at) from app_private.operations_work_sessions where actor_id=actor and ended_at is null)) into result;
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_METRICS_READ');return result;
end $$;

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
left join app_private.dining_tables t on t.id=n.table_id where j.status='EXCEPTION'
union all
select 'exceptions',j.id,'개인정보 정리','EXCEPTION',j.user_id,null,null,null,j.due_at,
 jsonb_build_object('domain','privacy','attempts',j.attempts,'nextAction','개인정보 정리 모니터에서 보존 조건과 인증 정리 상태를 확인하고 재시도')
from app_private.privacy_auth_jobs j where j.status='EXCEPTION';

revoke all on app_private.operations_entities from public,anon,authenticated,app_member_api;
