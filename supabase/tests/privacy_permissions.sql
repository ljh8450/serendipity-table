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
update app_private.intake_applications set input=jsonb_set(input,'{otherRegion}','"PRIVATE_FREE_TEXT"') where user_id=md5('withdraw-four-1user')::uuid;
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
 if exists(select 1 from app_private.intake_applications where user_id=md5('withdraw-four-1user')::uuid and (identity_snapshot<>'{}' or onboarding_snapshot<>'{}' or coalesce(input->>'otherRegion','')<>'' or payment_status<>'PAID')) then raise exception 'snapshot or financial mutation';end if;
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

-- Past participation remains factual while private free text and chat authority are removed.
select pg_temp.match_fixture('withdraw-past-',4);
select app_private.matching_tick();select app_private.chat_tick();
update app_private.intake_event_slots set starts_at=now()-interval '4 hours',closes_at=now()-interval '5 hours',matches_at=now()-interval '5 hours' where id=md5('withdraw-past-slot')::uuid;
update app_private.intake_applications set attendance_status='ATTENDED',input=jsonb_set(input,'{otherRegion}','"PRIVATE_PAST_TEXT"') where input->'slotIds' ? md5('withdraw-past-slot')::uuid::text;
select set_config('app.actor_id',md5('withdraw-past-1user')::uuid::text,true);
set local role app_member_api;
select app_private.privacy_withdraw(jsonb_build_object('requestKey',gen_random_uuid(),'confirmation','탈퇴'));
reset role;
do $$ declare room uuid;begin
 if not exists(select 1 from app_private.intake_applications where id=md5('withdraw-past-1app')::uuid and application_status='SUBMITTED' and matching_status='CONFIRMED' and attendance_status='ATTENDED' and input->>'otherRegion'='' and onboarding_snapshot='{}') then raise exception 'past attendance or free text minimization';end if;
 select r.id into room from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=md5('withdraw-past-slot')::uuid;
 if room is null then raise exception 'past fixture room missing';end if;
 begin perform app_private.chat_authorize(room,md5('withdraw-past-1user')::uuid);raise exception 'withdrawn chat access';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 if app_private.chat_authorize(room,md5('withdraw-past-2user')::uuid) is null then raise exception 'peer chat access removed';end if;
end $$;
rollback;
