begin;
select pg_advisory_xact_lock(hashtextextended('matching-state',0));
insert into auth.users(id) select md5('op01-user-'||i)::uuid from generate_series(0,27)i;
insert into app_private.member_accounts(user_id,role,username)
select md5('op01-user-'||i)::uuid,case when i=0 then 'operator' else 'participant' end,'op01_test_'||lpad(i::text,2,'0') from generate_series(0,27)i;
insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,capacity)
values(md5('op01-slot')::uuid,now()+interval '7 days',now()-interval '1 day',now()+interval '1 day',now()+interval '2 days','hongdae','OP01 TEST',24),
(md5('op01-other-slot')::uuid,now()+interval '8 days',now()-interval '1 day',now()+interval '1 day',now()+interval '2 days','hongdae','OP01 OTHER',24);
insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,submitted_at)
select md5('op01-app-'||i)::uuid,md5('op01-user-'||i)::uuid,gen_random_uuid(),
jsonb_build_object('slotIds',jsonb_build_array(md5('op01-slot')::uuid),'regions',jsonb_build_array('hongdae')),
'{"contact":"SECRET_CONTACT"}','{"birthYear":1995,"allergies":"SECRET_ALLERGY"}','google-form-v1','[]','{}',now() from generate_series(1,27)i;
insert into app_private.match_jobs(id,job_key,slot_id,due_at,status,last_error)
values(md5('op01-job')::uuid,'op01-test',md5('op01-slot')::uuid,now(),'EXCEPTION','SECRET_ERROR');
insert into app_private.match_runs(id,job_id,token,policy_version,policy_snapshot)
values(md5('op01-run')::uuid,md5('op01-job')::uuid,gen_random_uuid(),'match-v1','{}');
insert into app_private.dining_tables(id,run_id,slot_id,score,validation)
values(md5('op01-table')::uuid,md5('op01-run')::uuid,md5('op01-slot')::uuid,80,'{}');
insert into app_private.table_assignments(table_id,application_id,user_id,occupied_at)
values(md5('op01-table')::uuid,md5('op01-app-1')::uuid,md5('op01-user-1')::uuid,tstzrange(now()+interval '7 days',now()+interval '7 days 3 hours','[)'));


insert into app_private.table_assignments(table_id,application_id,user_id,occupied_at)
select md5('op01-table')::uuid,md5('op01-app-'||i)::uuid,md5('op01-user-'||i)::uuid,tstzrange(now()+interval '7 days',now()+interval '7 days 3 hours','[)') from generate_series(2,4)i;
update app_private.intake_event_slots set opens_at=now()-interval '2 days',closes_at=now()-interval '5 hours',matches_at=now()-interval '5 hours',starts_at=now()-interval '4 hours' where id=md5('op01-slot')::uuid;
update app_private.intake_applications set payment_status='PAID',matching_status='CONFIRMED',attendance_status=case when id=md5('op01-app-1')::uuid then 'ATTENDED' when id=md5('op01-app-3')::uuid then 'NO_SHOW' when id=md5('op01-app-4')::uuid then 'CANCELED_LATE' else 'SCHEDULED' end where id in(select md5('op01-app-'||i)::uuid from generate_series(1,4)i);
update app_private.intake_applications set application_status='CANCELED' where id=md5('op01-app-4')::uuid;
update app_private.table_assignments set active=false where application_id=md5('op01-app-4')::uuid;
insert into app_private.attendance_records(assignment_id,closed_at,review_status)
select id,now(),case when application_id=md5('op01-app-2')::uuid then 'PENDING' when application_id=md5('op01-app-3')::uuid then 'NO_SHOW' else 'ATTENDED' end from app_private.table_assignments where table_id=md5('op01-table')::uuid and active;
insert into app_private.event_feedback(assignment_id,user_id,request_key,ratings)
select id,user_id,gen_random_uuid(),'{"atmosphere":5,"conversation":4,"venue":3,"revisit":true,"recommend":false}' from app_private.table_assignments where application_id=md5('op01-app-1')::uuid;
insert into app_private.safety_reports(id,reporter_id,target_id,assignment_id,peer_id,category,details)
select md5('op02-report')::uuid,a.user_id,b.user_id,a.id,b.id,'OTHER','PRIVATE_REPORT_TEXT' from app_private.table_assignments a,app_private.table_assignments b where a.application_id=md5('op01-app-1')::uuid and b.application_id=md5('op01-app-3')::uuid;

update app_private.operations_measurement_config set since=now()-interval '1 day';
insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw)
select user_id,id,gen_random_uuid(),'success',9900 from app_private.intake_applications where id in(select md5('op01-app-'||i)::uuid from generate_series(1,4)i);

select set_config('test.start_key',(select request_key::text from app_private.intake_applications where id=md5('op01-app-1')::uuid),true);
set local role app_member_api;
select set_config('app.actor_id',md5('op01-user-1')::uuid::text,true);
do $$ declare d jsonb;begin
 d:=app_private.intake_start(jsonb_build_object('requestKey',current_setting('test.start_key'),'slotIds',jsonb_build_array(md5('op01-slot')::uuid)));if d->>'recorded'<>'true' then raise exception 'start not recorded';end if;
 perform app_private.intake_start(jsonb_build_object('requestKey',current_setting('test.start_key'),'slotIds',jsonb_build_array(md5('op01-slot')::uuid)));
 begin perform app_private.operations_metrics(jsonb_build_object('from',to_char(now()-interval '1 hour','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'to',to_char(now()+interval '1 day','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));raise exception 'participant metrics';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.operations_work(jsonb_build_object('action','start','slotId',md5('op01-slot')::uuid,'requestKey',gen_random_uuid()));raise exception 'participant work';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
end $$;
select set_config('app.actor_id',md5('op01-user-0')::uuid::text,true);
do $$ declare q jsonb;d jsonb;m jsonb;s jsonb;s2 jsonb;k uuid:=gen_random_uuid();stop uuid:=gen_random_uuid();begin
 q:=jsonb_build_object('from',to_char(now()-interval '1 hour','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'to',to_char(now()+interval '1 day','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'slotId',md5('op01-slot')::uuid);
 d:=app_private.operations_metrics(q);if jsonb_array_length(d->'metrics')<>13 or d::text like '%PRIVATE_REPORT_TEXT%' then raise exception 'metric DTO';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='applicationCompletion';if m->>'numerator'<>'1' or m->>'denominator'<>'1' then raise exception 'start dedup';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='paymentConversion';if m->>'numerator'<>'4' or m->>'denominator'<>'27' then raise exception 'payment cohort';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='matchingSuccess';if m->>'numerator'<>'3' or m->>'denominator'<>'4' then raise exception 'matching cohort';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='noShow';if m->>'numerator'<>'1' or m->>'denominator'<>'4' then raise exception 'candidate counted as no show';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='operatingTime';if m->'value'<>'null'::jsonb or m->>'coverage'<>'UNMEASURED' then raise exception 'unmeasured guessed';end if;
 s:=app_private.operations_work(jsonb_build_object('action','start','slotId',md5('op01-slot')::uuid,'requestKey',k));
 s2:=app_private.operations_work(jsonb_build_object('action','start','slotId',md5('op01-slot')::uuid,'requestKey',k));if s<>s2 then raise exception 'start replay';end if;
 begin perform app_private.operations_work(jsonb_build_object('action','start','slotId',md5('op01-slot')::uuid,'requestKey',gen_random_uuid()));raise exception 'overlap work allowed';exception when raise_exception then if sqlerrm<>'WORK_CONFLICT' then raise;end if;end;
 s:=app_private.operations_work(jsonb_build_object('action','stop','sessionId',s->>'id','requestKey',stop));
 s2:=app_private.operations_work(jsonb_build_object('action','stop','sessionId',s->>'id','requestKey',stop));if s<>s2 then raise exception 'stop replay';end if;
 d:=app_private.operations_metrics(q);if d->>'completedSessions'<>'1' or d->>'openSessions'<>'0' then raise exception 'time session';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='operatingTime';if (m->>'value')::numeric<0 or m->>'denominator'<>'1' then raise exception 'server duration';end if;
 perform set_config('app.operation_name','matching-retry',true);
 perform set_config('app.operation_payload',jsonb_build_object('jobId',md5('op01-job')::uuid)::text,true);
 perform app_private.match_retry(jsonb_build_object('jobId',md5('op01-job')::uuid));
 begin perform app_private.match_retry(jsonb_build_object('jobId',md5('op01-job')::uuid));raise exception 'resolved retry accepted';exception when raise_exception then if sqlerrm<>'JOB_CONFLICT' then raise;end if;end;
 perform set_config('app.operation_name','operations-metrics',true);
 d:=app_private.operations_metrics(q);select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='operatorIntervention';if m->>'numerator'<>'27' or m->>'denominator'<>'27' then raise exception 'scoped operator intervention';end if;
 d:=app_private.operations_metrics(jsonb_set(q,'{slotId}',to_jsonb(md5('op01-other-slot')::uuid)));if exists(select 1 from jsonb_array_elements(d->'metrics')x where x->>'unit'='ratio' and x->'value'<>'null'::jsonb) then raise exception 'zero denominator';end if;
 begin perform app_private.operations_metrics('{"from":"bad","to":"bad"}');raise exception 'invalid period accepted';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform app_private.operations_work(jsonb_build_object('action','stop','sessionId',gen_random_uuid(),'requestKey',gen_random_uuid()));raise exception 'forged session';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
end $$;
reset role;
-- Same-slot reallocation, explicit transfer, refund retries and future return are distinct facts.
insert into app_private.dining_tables(id,run_id,slot_id,status,score,validation) values(md5('op04-oldtable')::uuid,md5('op01-run')::uuid,md5('op01-slot')::uuid,'INVALIDATED',80,'{}');
insert into app_private.table_assignments(table_id,application_id,user_id,occupied_at,active) values(md5('op04-oldtable')::uuid,md5('op01-app-2')::uuid,md5('op01-user-2')::uuid,tstzrange(now()-interval '4 hours',now()-interval '1 hour','[)'),false);
insert into app_private.allocation_attempts(run_id,application_id,slot_id,step,reason) values(md5('op01-run')::uuid,md5('op01-app-5')::uuid,md5('op01-slot')::uuid,0,'ALTERNATIVE_OFFERED');
insert into app_private.match_resolutions(user_id,application_id,request_key,action,input,result) values(md5('op01-user-5')::uuid,md5('op01-app-5')::uuid,gen_random_uuid(),'transfer','{}','{}');
insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason) select md5('op01-user-4')::uuid,md5('op01-app-4')::uuid,id,gen_random_uuid(),9900,'failure','voluntary' from app_private.payment_attempts where application_id=md5('op01-app-4')::uuid;
insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason) select md5('op01-user-4')::uuid,md5('op01-app-4')::uuid,id,gen_random_uuid(),9900,'success','voluntary' from app_private.payment_attempts where application_id=md5('op01-app-4')::uuid;
insert into app_private.intake_applications(user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,submitted_at) values(md5('op01-user-1')::uuid,gen_random_uuid(),jsonb_build_object('slotIds',jsonb_build_array(md5('op01-other-slot')::uuid)),'{}','{}','google-form-v1','[]','{}',now()+interval '5 minutes');
set local role app_member_api;
do $$ declare d jsonb;m jsonb;begin
 d:=app_private.operations_metrics(jsonb_build_object('from',to_char(now()-interval '1 hour','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'to',to_char(now()+interval '1 day','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'slotId',md5('op01-slot')::uuid));
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='reallocationSuccess';if m->>'numerator'<>'1' or m->>'denominator'<>'2' then raise exception 'same-slot reallocation lost';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='alternativeConversion';if m->>'numerator'<>'1' or m->>'denominator'<>'1' then raise exception 'transfer lost';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='automaticRefund';if m->>'numerator'<>'1' or m->>'denominator'<>'1' then raise exception 'refund retry double counted';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='returnVisit';if m->>'numerator'<>'1' or m->>'denominator'<>'1' then raise exception 'future reapplication lost';end if;
end $$;
reset role;
-- Corrected attendance must change both no-show and feedback denominators.
update app_private.intake_applications set attendance_status='ATTENDED' where id=md5('op01-app-3')::uuid;
update app_private.attendance_records set review_status='ATTENDED' where assignment_id in(select id from app_private.table_assignments where application_id=md5('op01-app-3')::uuid);
set local role app_member_api;
do $$ declare d jsonb;m jsonb;begin
 d:=app_private.operations_metrics(jsonb_build_object('from',to_char(now()-interval '1 hour','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'to',to_char(now()+interval '1 day','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'slotId',md5('op01-slot')::uuid));
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='noShow';if m->>'numerator'<>'0' then raise exception 'no-show correction ignored';end if;
 select x into m from jsonb_array_elements(d->'metrics')x where x->>'id'='feedbackResponse';if m->>'numerator'<>'1' or m->>'denominator'<>'2' then raise exception 'feedback correction ignored';end if;
end $$;
reset role;
do $$ begin
 if (select count(*) from app_private.intake_starts where user_id=md5('op01-user-1')::uuid)<>1 or (select count(*) from app_private.operations_interventions where actor_id=md5('op01-user-0')::uuid)<>1 then raise exception 'measurement duplicate';end if;
 if has_function_privilege('authenticated','app_private.operations_metrics(jsonb)','execute') or has_function_privilege('anon','app_private.operations_work(jsonb)','execute') then raise exception 'public metrics/work';end if;
end $$;
rollback;
