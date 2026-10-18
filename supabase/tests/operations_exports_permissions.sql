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


set local role app_member_api;
select set_config('app.actor_id',md5('op01-user-1')::uuid::text,true);
do $$ begin begin perform app_private.operations_export('{"kind":"members"}');raise exception 'participant exported';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;
select set_config('app.actor_id',md5('op01-user-0')::uuid::text,true);
do $$ declare d jsonb;bad jsonb;begin
 d:=app_private.operations_export('{"kind":"applications","q":"op01_test_"}');
 if d->>'total'<>'27' or jsonb_array_length(d->'rows')<>27 or d->>'exportedAt' is null then raise exception 'page truncation or missing timestamp';end if;
 if d::text like '%SECRET%' or d::text like '%identity%' or d::text like '%birthYear%' then raise exception 'private export';end if;
 if exists(select 1 from jsonb_array_elements(d->'rows')r where (select count(*) from jsonb_object_keys(r))<>jsonb_array_length(d->'columns')) then raise exception 'column allowlist';end if;
 d:=app_private.operations_export(jsonb_build_object('kind','applications','memberId',md5('op01-user-1')::uuid));if d->>'total'<>'1' then raise exception 'member filter lost';end if;
 d:=app_private.operations_export('{"kind":"applications","q":"op01_test_","paymentStatus":"PAID"}');if d->>'total'<>'0' then raise exception 'state filter lost';end if;
 d:=app_private.operations_export(jsonb_build_object('kind','applications','q','op01_test_','from',to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));if d->>'total'<>'27' then raise exception 'inclusive period start';end if;
 d:=app_private.operations_export(jsonb_build_object('kind','applications','q','op01_test_','to',to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));if d->>'total'<>'0' then raise exception 'exclusive period end';end if;
 foreach bad in array array['{"kind":"members","page":0}'::jsonb,'{"kind":"members","id":"forged"}','{"kind":"members","actorId":"forged"}',jsonb_build_object('kind','applications','slotId',gen_random_uuid())] loop
 begin perform app_private.operations_export(bad);raise exception 'invalid export allowed';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;end loop;
 begin perform * from app_private.operations_exports;raise exception 'audit table accessible';exception when insufficient_privilege then null;end;
end $$;
reset role;
do $$ begin
 if (select count(*) from app_private.operations_exports where actor_id=md5('op01-user-0')::uuid)<>5 then raise exception 'export audit';end if;
 if not exists(select 1 from app_private.operations_exports where actor_id=md5('op01-user-0')::uuid and row_count=27 and filters->>'q'='op01_test_') then raise exception 'audit filters/count';end if;
 if has_function_privilege('anon','app_private.operations_export(jsonb)','execute') or has_function_privilege('authenticated','app_private.operations_export(jsonb)','execute') then raise exception 'public export';end if;
end $$;
-- Exceeding the safety bound must fail rather than silently exporting a partial file.
insert into auth.users(id) select md5('op03-limit-'||i)::uuid from generate_series(1,5001)i;
insert into app_private.member_accounts(user_id,username) select md5('op03-limit-'||i)::uuid,'op03_limit_'||i from generate_series(1,5001)i;
set local role app_member_api;
do $$ begin begin perform app_private.operations_export('{"kind":"members","q":"op03_limit_"}');raise exception 'truncated export allowed';exception when raise_exception then if sqlerrm<>'EXPORT_LIMIT' then raise;end if;end;end $$;
reset role;
do $$ begin if (select count(*) from app_private.operations_exports where actor_id=md5('op01-user-0')::uuid)<>5 then raise exception 'failed export recorded as success';end if;end $$;
rollback;
