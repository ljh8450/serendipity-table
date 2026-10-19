begin;
-- Isolate catalog inside this rollback transaction; preserve preexisting local fixtures.
select pg_advisory_xact_lock(hashtextextended('matching-state',0));
update app_private.intake_event_slots set published=false;
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

create function pg_temp.person_fixture(label text) returns uuid language plpgsql as $$
declare s uuid;begin
 s:=pg_temp.match_fixture(label,4);
 update app_private.intake_applications set onboarding_snapshot=jsonb_set(onboarding_snapshot,'{gender}','"male"') where input->'slotIds' ? s::text;
 perform app_private.matching_tick();perform app_private.chat_tick();
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=s;
 update app_private.intake_applications set attendance_status='ATTENDED' where input->'slotIds' ? s::text;
 update app_private.table_assignments ta set occupied_at=tstzrange(e.starts_at,e.starts_at+interval '3 hours','[)') from app_private.dining_tables t join app_private.intake_event_slots e on e.id=t.slot_id where ta.table_id=t.id and t.slot_id=s;
 return s;
end $$;
do $$ declare s uuid;actor uuid:=md5('return-basic1user')::uuid; dto jsonb;count_before int;ta uuid;
begin
 s:=pg_temp.person_fixture('return-basic');
 select id into ta from app_private.table_assignments where user_id=actor;
 perform set_config('app.actor_id',actor::text,true);
 update app_private.intake_applications set input=jsonb_set(input,'{regions}','["hongdae","jamsil"]') where user_id=actor;
 insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity)
 select md5('return-slot'||i)::uuid,clock_timestamp()+make_interval(days=>i+1),clock_timestamp()-interval '1 day',clock_timestamp()+interval '1 day',clock_timestamp()+interval '1 day',case when i=1 then 'jamsil' else 'hongdae' end,'LOCAL RETURN TEST',true,24 from generate_series(1,9)i;
 -- Exclude every unpublished/not-yet-open/closed/foreign-region slot.
 update app_private.intake_event_slots set published=false where id=md5('return-slot6')::uuid;
 update app_private.intake_event_slots set opens_at=clock_timestamp()+interval '1 hour' where id=md5('return-slot7')::uuid;
 update app_private.intake_event_slots set closes_at=clock_timestamp()-interval '1 minute',matches_at=clock_timestamp()-interval '1 minute' where id=md5('return-slot8')::uuid;
 update app_private.intake_event_slots set region_code='gangnam' where id=md5('return-slot9')::uuid;
 select count(*) into count_before from app_private.intake_applications;
 dto:=app_private.return_recommendations_get();
 if dto->>'status'<>'AVAILABLE' or jsonb_array_length(dto->'items')<>5 or dto#>>'{items,0,id}'<>md5('return-slot1')::uuid::text then raise exception 'fallback rank or limit';end if;
 -- An explicitly selected weekday/hour outranks an earlier nonmatching date.
 update app_private.intake_event_slots set starts_at=(select starts_at+interval '7 days' from app_private.intake_event_slots where id=s) where id=md5('return-slot5')::uuid;
 dto:=app_private.return_recommendations_get();
 if dto#>>'{items,0,id}'<>md5('return-slot5')::uuid::text or dto#>>'{items,0,datePreference}'<>'true' then raise exception 'date preference ranking';end if;
 update app_private.intake_event_slots set starts_at=clock_timestamp()+interval '6 days' where id=md5('return-slot5')::uuid;
 insert into app_private.event_feedback(assignment_id,user_id,request_key,ratings)values(ta,actor,gen_random_uuid(),'{"atmosphere":5,"conversation":5,"venue":5,"revisit":true,"recommend":true}');
 dto:=app_private.return_recommendations_get();
 if dto#>>'{items,0,id}'<>md5('return-slot2')::uuid::text or dto#>>'{items,0,reason}'<>'POSITIVE_EXPERIENCE' then raise exception 'own feedback rank';end if;
 update app_private.event_feedback set ratings=jsonb_set(ratings,'{revisit}','false') where user_id=actor;
 insert into app_private.event_feedback(assignment_id,user_id,request_key,ratings)
 select id,user_id,gen_random_uuid(),'{"atmosphere":5,"conversation":5,"venue":5,"revisit":true,"recommend":true}'
 from app_private.table_assignments where user_id=md5('return-basic2user')::uuid;
 dto:=app_private.return_recommendations_get();
 if dto#>>'{items,0,id}'<>md5('return-slot1')::uuid::text then raise exception 'peer feedback influenced caller';end if;
 update app_private.event_feedback set ratings=jsonb_set(ratings,'{revisit}','true') where user_id=actor;
 dto:=app_private.return_recommendations_get();
 if exists(select 1 from jsonb_array_elements(dto->'items')x where x->>'id' in(select md5('return-slot'||i)::uuid::text from generate_series(6,9)i)) then raise exception 'unavailable slot leaked';end if;
 if (select count(*) from app_private.intake_applications)<>count_before then raise exception 'read performed application write';end if;
 if (select count(*) from jsonb_object_keys(dto))<>2 or exists(select 1 from jsonb_array_elements(dto->'items')x where (select count(*) from jsonb_object_keys(x))<>7) then raise exception 'DTO shape';end if;
 -- No submitted duplicate; no overlapping active assignment.
 update app_private.intake_applications set input=jsonb_set(input,'{slotIds}',input->'slotIds'||jsonb_build_array(md5('return-slot2')::uuid)) where user_id=actor;
 dto:=app_private.return_recommendations_get();
 if exists(select 1 from jsonb_array_elements(dto->'items')x where x->>'id'=md5('return-slot2')::uuid::text) then raise exception 'duplicate recommended';end if;
 update app_private.table_assignments set occupied_at=tstzrange((select starts_at from app_private.intake_event_slots where id=md5('return-slot3')::uuid),(select starts_at+interval '3 hours' from app_private.intake_event_slots where id=md5('return-slot3')::uuid),'[)') where id=ta;
 dto:=app_private.return_recommendations_get();
 if exists(select 1 from jsonb_array_elements(dto->'items')x where x->>'id'=md5('return-slot3')::uuid::text) then raise exception 'overlap recommended';end if;
 insert into app_private.safety_accounts(user_id,state) values(actor,'RESTRICTED');
 if app_private.return_recommendations_get()->>'status'<>'RESTRICTED' then raise exception 'restriction ignored';end if;
 update app_private.safety_accounts set state='ACTIVE' where user_id=actor;
 update app_private.intake_applications set attendance_status='NO_SHOW' where user_id=actor;
 if app_private.return_recommendations_get()->>'status'<>'NO_HISTORY' then raise exception 'corrected attendance retained history';end if;
 update app_private.intake_applications set attendance_status='ATTENDED' where user_id=actor;
 update app_private.intake_event_slots set published=false where region_label='LOCAL RETURN TEST';
 if app_private.return_recommendations_get()->>'status'<>'NO_OPEN_SLOTS' then raise exception 'unpublication not current';end if;
 -- A peer's valid feedback cannot personalize an actor without valid attendance.
 perform set_config('app.actor_id',md5('return-basic2user')::uuid::text,true);
 update app_private.intake_applications set attendance_status='NO_SHOW' where user_id=md5('return-basic2user')::uuid;
 if app_private.return_recommendations_get()->>'status'<>'NO_HISTORY' then raise exception 'other actor history leaked';end if;
 if has_function_privilege('anon','app_private.return_recommendations_get()','EXECUTE') or has_function_privilege('authenticated','app_private.return_recommendations_get()','EXECUTE') then raise exception 'public RPC grant';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('return-basic1user')::uuid::text,true);
select app_private.return_recommendations_get();
reset role;
rollback;
