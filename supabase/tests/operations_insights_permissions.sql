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
set local role app_member_api;
select set_config('app.actor_id',md5('op01-user-1')::uuid::text,true);
do $$ begin begin perform app_private.operations_insights(jsonb_build_object('tableId',md5('op01-table')::uuid));raise exception 'participant allowed';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;
select set_config('app.actor_id',md5('op01-user-0')::uuid::text,true);
do $$ declare d jsonb;bad jsonb;begin
 d:=app_private.operations_insights(jsonb_build_object('slotId',md5('op01-slot')::uuid,'tableId',md5('op01-table')::uuid));
 if d#>>'{attendance,assigned}'<>'3' or d#>>'{attendance,attended}'<>'1' or d#>>'{attendance,noShowCandidates}'<>'1' or d#>>'{attendance,confirmedNoShows}'<>'1' or d#>>'{attendance,lateCancellations}'<>'1' then raise exception 'attendance aggregate';end if;
 if d#>>'{feedback,eligible}'<>'1' or d#>>'{feedback,responses}'<>'1' or (d#>>'{feedback,atmosphere}')::numeric<>5 or d->>'totalCases'<>'4' then raise exception 'feedback or cases aggregate';end if;
 if d::text like '%PRIVATE_REPORT_TEXT%' or d::text like '%reporter%' or (d->>'canReviewSafety')::boolean then raise exception 'sensitive case leak';end if;
 begin perform app_private.operations_safety_detail(jsonb_build_object('caseType','REPORT','caseId',md5('op02-report')::uuid));raise exception 'review authority bypass';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 d:=app_private.operations_insights(jsonb_build_object('slotId',md5('op01-other-slot')::uuid));if d->>'totalCases'<>'0' or d#>>'{feedback,eligible}'<>'0' or d#>'{feedback,atmosphere}'<>'null'::jsonb then raise exception 'scope or zero denominator';end if;
 foreach bad in array array['{}'::jsonb,'null','{"tableId":"bad"}',jsonb_build_object('slotId',md5('op01-other-slot')::uuid,'tableId',md5('op01-table')::uuid),jsonb_build_object('tableId',md5('op01-table')::uuid,'actorId','forged')] loop
 begin perform app_private.operations_insights(bad);raise exception 'invalid scope allowed';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;end loop;
end $$;
reset role;
-- A later attendance correction removes the response from aggregates without deleting the historical rating.
update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('op01-app-1')::uuid;
update app_private.attendance_records set review_status='NO_SHOW' where assignment_id in(select id from app_private.table_assignments where application_id=md5('op01-app-1')::uuid);
insert into app_private.safety_reviewers(user_id) values(md5('op01-user-0')::uuid);
set local role app_member_api;
do $$ declare d jsonb;begin
 d:=app_private.operations_insights(jsonb_build_object('tableId',md5('op01-table')::uuid));if d#>>'{feedback,responses}'<>'0' or d#>>'{feedback,eligible}'<>'0' or not (d->>'canReviewSafety')::boolean then raise exception 'correction or review permission';end if;
 d:=app_private.operations_safety_detail(jsonb_build_object('caseType','REPORT','caseId',md5('op02-report')::uuid));if d->>'details'<>'PRIVATE_REPORT_TEXT' then raise exception 'authorized detail';end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from app_private.member_audit where actor_id=md5('op01-user-0')::uuid and action='OPERATIONS_INSIGHTS_READ') then raise exception 'missing audit';end if;
 if has_function_privilege('authenticated','app_private.operations_insights(jsonb)','execute') or has_function_privilege('anon','app_private.operations_insights(jsonb)','execute') then raise exception 'public execute';end if;
end $$;
rollback;
