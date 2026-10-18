begin;
create function pg_temp.match_fixture(label text,num int,year_gap int default 0) returns uuid language plpgsql as $$
declare slot uuid:=md5(label||'slot')::uuid; usr uuid; app uuid; i int;
begin
 insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity) values(slot,now()+interval '7 days',now()-interval '1 day',now()-interval '2 minutes',now()-interval '1 minute','hongdae','LOCAL MATCH TEST',true,240);
 for i in 1..num loop
  usr:=md5(label||i||'user')::uuid;app:=md5(label||i||'app')::uuid;
  insert into auth.users(id) values(usr);
  insert into app_private.member_accounts(user_id) values(usr);
  insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
  values(app,usr,gen_random_uuid(),jsonb_build_object('slotIds',jsonb_build_array(slot),'regions',jsonb_build_array('hongdae'),'ticketCode','single_v2','otherRegion',''),'{}',jsonb_build_object('birthYear',1995+case when i=num then year_gap else 0 end,'gender',case when i%2=0 then 'male' else 'female' end,'mbti',jsonb_build_array('INTJ'),'interests',jsonb_build_array('film'),'traits',jsonb_build_array('calm'),'preferredTraits',jsonb_build_array('calm')),'google-form-v1','[]','{"code":"single_v2","kind":"single","amountKrw":9900,"policyVersion":"faq-v1"}','PAID');
  insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values(usr,app,gen_random_uuid(),'success',9900);
 end loop;
 return slot;
end $$;

select pg_temp.match_fixture('withdraw-four-',4);
select pg_temp.match_fixture('withdraw-five-',5);
select app_private.matching_tick();
insert into app_private.intake_members(user_id,identity,onboarding) values(md5('withdraw-four-1user')::uuid,'{"name":"PRIVATE_NAME","contact":"PRIVATE_CONTACT"}','{"allergies":"PRIVATE_ALLERGY"}');
select set_config('app.actor_id',md5('withdraw-four-1user')::uuid::text,true);
select set_config('test.withdraw_key',gen_random_uuid()::text,true);
set local role app_member_api;
do $$ declare d jsonb;again jsonb;begin
 d:=app_private.privacy_withdraw(jsonb_build_object('requestKey',current_setting('test.withdraw_key'),'confirmation','탈퇴'));
 if d->>'withdrawn'<>'true' or d->>'authCleanupPending'<>'true' or d->>'unresolvedFinancialApplications'<>'1' then raise exception 'withdrawal receipt/rights';end if;
 again:=app_private.privacy_withdraw(jsonb_build_object('requestKey',current_setting('test.withdraw_key'),'confirmation','탈퇴'));if d<>again then raise exception 'withdrawal replay';end if;
 begin perform app_private.member_get();raise exception 'withdrawn member authorized';exception when insufficient_privilege then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.privacy_withdraw(jsonb_build_object('requestKey',gen_random_uuid(),'confirmation','탈퇴'));raise exception 'different key allowed';exception when raise_exception then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 begin perform app_private.privacy_withdraw(jsonb_build_object('requestKey',gen_random_uuid(),'confirmation','탈퇴','userId',md5('withdraw-five-1user')::uuid));raise exception 'spoofed actor accepted';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform * from app_private.member_withdrawals;raise exception 'private withdrawal table accessible';exception when insufficient_privilege then null;end;
end $$;
reset role;
do $$ declare t uuid;begin
 if app_private.safety_allowed(md5('withdraw-four-1user')::uuid) then raise exception 'withdrawn matching eligibility';end if;
 if exists(select 1 from app_private.intake_members where user_id=md5('withdraw-four-1user')::uuid) then raise exception 'profile retained';end if;
 if exists(select 1 from app_private.intake_applications where user_id=md5('withdraw-four-1user')::uuid and (identity_snapshot<>'{}' or onboarding_snapshot<>'{}' or payment_status<>'PAID')) then raise exception 'snapshot or financial mutation';end if;
 if not exists(select 1 from app_private.payment_attempts where user_id=md5('withdraw-four-1user')::uuid and outcome='success') then raise exception 'financial ledger erased';end if;
 select table_id into t from app_private.table_assignments where application_id=md5('withdraw-four-1app')::uuid;
 if (select status from app_private.dining_tables where id=t)<>'INVALIDATED' or exists(select 1 from app_private.table_assignments where table_id=t and active) then raise exception 'three-person table confirmed';end if;
 if (select count(*) from app_private.intake_applications where id in(select md5('withdraw-four-'||i||'app')::uuid from generate_series(2,4)i) and matching_status='REALLOCATING')<>3 then raise exception 'remaining participants not repaired';end if;
 begin insert into app_private.intake_members(user_id,identity) values(md5('withdraw-four-1user')::uuid,'{"name":"racing rewrite"}');raise exception 'racing personal rewrite accepted';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
end $$;
select set_config('app.actor_id',md5('withdraw-five-1user')::uuid::text,true);
set local role app_member_api;
select app_private.privacy_withdraw(jsonb_build_object('requestKey',gen_random_uuid(),'confirmation','탈퇴'));
reset role;
do $$ declare t uuid;begin
 select table_id into t from app_private.table_assignments where application_id=md5('withdraw-five-1app')::uuid;
 if (select status from app_private.dining_tables where id=t)<>'CONFIRMED' or (select count(*) from app_private.table_assignments where table_id=t and active)<>4 then raise exception 'valid four-person table lost';end if;
 if (select count(*) from app_private.member_withdrawals)<>(select count(*) from app_private.member_withdrawals where user_id not in(md5('withdraw-four-1user')::uuid,md5('withdraw-five-1user')::uuid))+2 then raise exception 'duplicate withdrawal';end if;
 if has_function_privilege('anon','app_private.privacy_withdraw(jsonb)','execute') or has_function_privilege('authenticated','app_private.privacy_get()','execute') then raise exception 'public privacy command';end if;
end $$;

-- Synthetic time shifts below are fixtures, never caller-controlled policy time.
insert into auth.users(id) values(md5('privacy-expired-user')::uuid),(md5('privacy-test-operator')::uuid);
insert into app_private.member_accounts(user_id,role) values(md5('privacy-expired-user')::uuid,'participant'),(md5('privacy-test-operator')::uuid,'operator');
select set_config('app.actor_id',md5('privacy-expired-user')::uuid::text,true);
select app_private.privacy_withdraw(jsonb_build_object('requestKey',gen_random_uuid(),'confirmation','탈퇴'));
update app_private.privacy_auth_jobs set status='DONE' where kind='SOFT_DELETE' and user_id in(md5('privacy-expired-user')::uuid,md5('withdraw-four-1user')::uuid,md5('withdraw-five-1user')::uuid);
update app_private.member_withdrawals set withdrawn_at=now()-interval '7 years',financial_until=now()-interval '1 day',safety_until=now()-interval '1 day',audit_until=now()-interval '1 day' where user_id in(md5('privacy-expired-user')::uuid,md5('withdraw-four-1user')::uuid,md5('withdraw-five-1user')::uuid);
update app_private.payment_attempts set created_at=now()-interval '7 years' where user_id in(md5('withdraw-four-1user')::uuid,md5('withdraw-five-1user')::uuid);
update app_private.member_audit set occurred_at=now()-interval '7 years' where actor_id=md5('privacy-expired-user')::uuid;
insert into app_private.privacy_holds(user_id,kind,reason,expires_at) values(md5('privacy-expired-user')::uuid,'LEGAL','LOCAL TEST HOLD',now()+interval '1 day');
select app_private.privacy_retention_tick();
do $$ begin
 if exists(select 1 from app_private.privacy_auth_jobs where user_id in(md5('privacy-expired-user')::uuid,md5('withdraw-four-1user')::uuid,md5('withdraw-five-1user')::uuid) and kind='HARD_DELETE') then raise exception 'legal or financial hold bypassed';end if;
 if not exists(select 1 from app_private.payment_attempts where user_id=md5('withdraw-four-1user')::uuid) then raise exception 'unresolved financial rights erased';end if;
end $$;
delete from app_private.privacy_holds where user_id=md5('privacy-expired-user')::uuid;
select app_private.privacy_retention_tick();
do $$ declare j jsonb;begin
 if (select count(*) from app_private.privacy_auth_jobs where user_id=md5('privacy-expired-user')::uuid and kind='HARD_DELETE')<>1 then raise exception 'expired account not queued';end if;
 j:=app_private.privacy_claim();if j->>'userId'<>md5('privacy-expired-user')::uuid::text then raise exception 'claim scope';end if;
 begin perform app_private.privacy_finish((j->>'id')::uuid,gen_random_uuid(),true);raise exception 'stale claim accepted';exception when raise_exception then if sqlerrm<>'STALE_CLAIM' then raise;end if;end;
 insert into app_private.privacy_holds(user_id,kind,reason,expires_at) values(md5('privacy-expired-user')::uuid,'LEGAL','NEW CLAIMED HOLD',now()+interval '1 day');
 begin perform app_private.privacy_hard_prepare((j->>'id')::uuid,(j->>'token')::uuid);raise exception 'claimed job bypassed new hold';exception when raise_exception then if sqlerrm<>'RETENTION_HOLD' then raise;end if;end;
 delete from app_private.privacy_holds where user_id=md5('privacy-expired-user')::uuid;
 perform app_private.privacy_hard_prepare((j->>'id')::uuid,(j->>'token')::uuid);
 begin insert into app_private.privacy_holds(user_id,kind,reason,expires_at) values(md5('privacy-expired-user')::uuid,'LEGAL','TOO LATE HOLD',now()+interval '1 day');raise exception 'finalization race accepted';exception when raise_exception then if sqlerrm<>'PRIVACY_ALREADY_FINALIZED' then raise;end if;end;
 if app_private.privacy_auth_complete((j->>'id')::uuid,(j->>'token')::uuid) then raise exception 'Auth complete guessed before removal';end if;
 delete from auth.users where id=md5('privacy-expired-user')::uuid;
 if not app_private.privacy_auth_complete((j->>'id')::uuid,(j->>'token')::uuid) then raise exception 'Auth removal not verified';end if;
 perform app_private.privacy_finish((j->>'id')::uuid,(j->>'token')::uuid,true);
 if not exists(select 1 from app_private.member_withdrawals where user_id=md5('privacy-expired-user')::uuid and hard_deleted_at is not null) then raise exception 'hard deletion receipt missing';end if;
end $$;
-- Once a protected credit is actually refunded, retain the transaction until its own deadline.
insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason,created_at)
select user_id,application_id,id,gen_random_uuid(),9900,'success','voluntary',now()-interval '7 years' from app_private.payment_attempts where user_id=md5('withdraw-five-1user')::uuid;
update app_private.intake_applications set payment_status='REFUNDED' where user_id=md5('withdraw-five-1user')::uuid;
update app_private.member_audit set occurred_at=now()-interval '7 years' where actor_id=md5('withdraw-five-1user')::uuid;
select app_private.privacy_retention_tick();
do $$ declare j jsonb;begin
 j:=app_private.privacy_claim();if j->>'userId'<>md5('withdraw-five-1user')::uuid::text then raise exception 'settled credit not eligible';end if;
 perform app_private.privacy_hard_prepare((j->>'id')::uuid,(j->>'token')::uuid);
 delete from auth.users where id=md5('withdraw-five-1user')::uuid;
 perform app_private.privacy_finish((j->>'id')::uuid,(j->>'token')::uuid,true);
 if (select count(*) from app_private.table_assignments where table_id in(select id from app_private.dining_tables where slot_id=md5('withdraw-five-slot')::uuid) and active)<>4 then raise exception 'peer assignment erased by account purge';end if;
 if exists(select 1 from app_private.match_runs r,jsonb_array_elements(r.input_snapshot)x where x->>'applicationId'=md5('withdraw-five-1app')::uuid::text) then raise exception 'run input retained purged subject';end if;
end $$;
select set_config('app.actor_id',md5('privacy-test-operator')::uuid::text,true);
update app_private.privacy_auth_jobs set status='EXCEPTION' where user_id=md5('withdraw-four-1user')::uuid and kind='SOFT_DELETE';
set local role app_member_api;
do $$ declare j uuid;d jsonb;begin
 d:=app_private.operations_privacy_get();if (d->>'retentionHeld')::int<1 or d::text like '%PRIVATE%' then raise exception 'retention monitor scope';end if;
 select (x->>'id')::uuid into j from jsonb_array_elements(d->'jobs')x where x->>'status'='EXCEPTION';
 perform set_config('app.operation_name','privacy-retry',true);perform set_config('app.operation_payload',jsonb_build_object('jobId',j)::text,true);
 perform app_private.operations_privacy_retry(jsonb_build_object('jobId',j));
 begin perform app_private.operations_privacy_retry(jsonb_build_object('jobId',j));raise exception 'resolved retry allowed';exception when raise_exception then if sqlerrm<>'JOB_CONFLICT' then raise;end if;end;
 perform set_config('app.operation_name','',true);
 begin perform app_private.privacy_claim();raise exception 'member dispatcher access';exception when insufficient_privilege then null;end;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from app_private.operations_interventions where actor_id=md5('privacy-test-operator')::uuid and subject_user_id=md5('withdraw-four-1user')::uuid and command='privacy-retry') then raise exception 'privacy retry intervention missing';end if;
 if has_function_privilege('app_member_api','app_private.privacy_retention_tick()','execute') or has_function_privilege('anon','app_private.privacy_claim()','execute') then raise exception 'public cleanup worker';end if;
 if (select count(*) from cron.job where jobname in('serendipity-privacy-retention','serendipity-privacy-auth') and active)<>2 then raise exception 'privacy server cron missing';end if;
end $$;
rollback;
