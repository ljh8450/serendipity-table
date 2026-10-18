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
do $$ begin
 begin perform app_private.operations_explore('{"kind":"members"}');raise exception 'participant allowed';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform * from app_private.operations_entities;raise exception 'view accessible';exception when insufficient_privilege then null;end;
end $$;
select set_config('app.actor_id',md5('op01-user-0')::uuid::text,true);
do $$ declare d jsonb;p jsonb;bad jsonb;before_count int;begin
 d:=app_private.operations_explore('{"kind":"applications","q":"op01_test_"}');
 p:=app_private.operations_explore('{"kind":"applications","q":"op01_test_","page":1}');
 if (d->>'total')::int<>27 or jsonb_array_length(d->'items')<>25 or jsonb_array_length(p->'items')<>2 then raise exception 'pagination';end if;
 if exists(select 1 from jsonb_array_elements(d->'items')a join jsonb_array_elements(p->'items')b on a->>'id'=b->>'id') then raise exception 'page overlap';end if;
 if d::text like '%SECRET%' or d::text like '%birthYear%' then raise exception 'private field leak';end if;
 if (select count(*) from jsonb_object_keys(d))<>4 or exists(select 1 from jsonb_array_elements(d->'items')a where (select count(*) from jsonb_object_keys(a))<>10) then raise exception 'DTO shape';end if;
 d:=app_private.operations_explore('{"kind":"applications","q":"%"}');if (d->>'total')::int<>0 then raise exception 'wildcard search';end if;
 d:=app_private.operations_explore('{"kind":"applications","q":"op01_test_","paymentStatus":"PAID"}');if (d->>'total')::int<>0 then raise exception 'payment filter';end if;
 d:=app_private.operations_explore(jsonb_build_object('kind','applications','memberId',md5('op01-user-1')::uuid));if (d->>'total')::int<>1 then raise exception 'member scope';end if;
 d:=app_private.operations_explore(jsonb_build_object('kind','applications','slotId',md5('op01-slot')::uuid));if (d->>'total')::int<>27 then raise exception 'slot scope';end if;
 d:=app_private.operations_explore(jsonb_build_object('kind','applications','tableId',md5('op01-table')::uuid));if (d->>'total')::int<>1 then raise exception 'table scope';end if;
 d:=app_private.operations_explore(jsonb_build_object('kind','tables','id',md5('op01-table')::uuid));if d#>>'{items,0,facts,activeCount}'<>'1' then raise exception 'table detail';end if;
 d:=app_private.operations_explore(jsonb_build_object('kind','exceptions','slotId',md5('op01-slot')::uuid));if (d->>'total')::int<>1 or d::text like '%SECRET%' then raise exception 'exception projection';end if;
 foreach bad in array array['{}'::jsonb,'null','[]','{"kind":"members","actorId":"forged"}','{"kind":"members","page":-1}','{"kind":"members","page":10000}','{"kind":"members","q":3}','{"kind":"members","id":"bad"}',jsonb_build_object('kind','slots','id',md5('op01-slot')::uuid,'slotId',md5('op01-other-slot')::uuid),jsonb_build_object('kind','members','slotId',gen_random_uuid())] loop
 begin perform app_private.operations_explore(bad);raise exception 'invalid input allowed';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 end loop;
end $$;
reset role;
do $$ declare d jsonb;begin
 if not exists(select 1 from app_private.member_audit where actor_id=md5('op01-user-0')::uuid and action='OPERATIONS_EXPLORE_APPLICATIONS') then raise exception 'missing read audit';end if;
 update app_private.match_jobs set status='DONE',last_error=null where id=md5('op01-job')::uuid;
 perform set_config('app.actor_id',md5('op01-user-0')::uuid::text,true);
 d:=app_private.operations_explore(jsonb_build_object('kind','exceptions','slotId',md5('op01-slot')::uuid));if (d->>'total')::int<>0 then raise exception 'resolved exception listed';end if;
 if has_function_privilege('anon','app_private.operations_explore(jsonb)','execute') or has_function_privilege('authenticated','app_private.operations_explore(jsonb)','execute') then raise exception 'public execution';end if;
 if (select count(*) from app_private.intake_applications where user_id in(select md5('op01-user-'||i)::uuid from generate_series(1,27)i) and payment_status='PENDING' and matching_status='WAITING')<>27 then raise exception 'domain state mutated';end if;
end $$;
rollback;
