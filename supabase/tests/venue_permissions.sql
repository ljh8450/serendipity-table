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

insert into auth.users(id) values(md5('venue-operator')::uuid);
insert into app_private.member_accounts(user_id,role) values(md5('venue-operator')::uuid,'operator');
create function pg_temp.venue_fixture(label text,num int default 4) returns uuid language plpgsql as $$
declare slot uuid;
begin
 slot:=pg_temp.match_fixture(label,num);
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["10_20"],"allergies":"","avoidedFoods":""}' where input->'slotIds' ? slot::text;
 perform app_private.matching_tick();return slot;
end $$;
create function pg_temp.venue_payload(slot uuid,label text,price int default 15000,seats int default 6) returns jsonb language sql as $$
 select jsonb_build_object('requestKey',gen_random_uuid(),'slotId',slot,'name','LOCAL TEST '||label,'address','LOCAL TEST ADDRESS','mapUrl','https://example.test/map','reservationName',label,'mealPriceKrw',price,'seats',seats,'rating',4.5,'reviewCount',40,'reviewUrl','https://example.test/review','verifiedAt',clock_timestamp()-interval '1 hour','reservationValidUntil',clock_timestamp()+interval '8 days','safeAllergies','[]'::jsonb,'safeAvoidedFoods','[]'::jsonb,'verificationNote','LOCAL VERIFIED FIXTURE ONLY','reservationConfirmed',true)
$$;
do $$ declare s uuid;t uuid;payload jsonb;inv uuid;alloc uuid;dto jsonb;cases text;price int;v app_private.venue_inventory%rowtype;
begin
 s:=pg_temp.venue_fixture('venue-basic');select id into t from app_private.dining_tables where slot_id=s;
 perform app_private.venue_tick();
 if not exists(select 1 from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id where o.aggregate_id=t and r.last_error='VENUE_NO_COMPATIBLE_INVENTORY') then raise exception 'stock shortage not visible';end if;
 for price in 1..2 loop update app_private.venue_receipts set due_at=clock_timestamp() where status='QUEUED';perform app_private.venue_tick();end loop;
 if not exists(select 1 from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id where o.aggregate_id=t and r.status='EXCEPTION') then raise exception 'retry budget';end if;
 payload:=pg_temp.venue_payload(s,'basic');perform set_config('app.actor_id',md5('venue-basic1user')::uuid::text,true);
 begin perform app_private.operations_venue_create(payload);raise exception 'participant registered';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);
 perform app_private.operations_venue_create(payload);perform app_private.operations_venue_create(payload);
 if (select count(*) from app_private.venue_inventory where slot_id=s)<>1 then raise exception 'duplicate request stock';end if;
 begin perform app_private.operations_venue_create(payload||'{"seats":4}');raise exception 'changed idem';exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 begin perform app_private.operations_venue_create(payload||jsonb_build_object('requestKey',gen_random_uuid(),'name',lower(payload->>'name')));raise exception 'duplicate reservation';exception when others then if sqlerrm<>'VENUE_DUPLICATE' then raise;end if;end;
 perform app_private.venue_tick();perform app_private.venue_tick();
 select id into alloc from app_private.venue_allocations where table_id=t and active;
 if alloc is null or (select count(*) from app_private.venue_allocations where table_id=t)<>1 then raise exception 'missing/duplicate allocation';end if;
 select * into v from app_private.venue_inventory where id=(select inventory_id from app_private.venue_allocations where id=alloc);
 v.meal_price_krw:=20000;if not app_private.venue_compatible(v,t) then raise exception '20k boundary';end if;
 v.meal_price_krw:=20001;if app_private.venue_compatible(v,t) then raise exception '20k overflow';end if;
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["20_30"]}' where input->'slotIds' ? s::text;
 v.meal_price_krw:=30000;if not app_private.venue_compatible(v,t) then raise exception '30k boundary';end if;
 v.meal_price_krw:=30001;if app_private.venue_compatible(v,t) then raise exception '30k overflow';end if;
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["30_plus"]}' where input->'slotIds' ? s::text;
 v.meal_price_krw:=30000;if not app_private.venue_compatible(v,t) then raise exception '30plus boundary';end if;
 v.meal_price_krw:=29999;if app_private.venue_compatible(v,t) then raise exception '30plus underflow';end if;
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["10_20"]}' where input->'slotIds' ? s::text;
 if exists(select 1 from app_private.match_outbox where aggregate_id=t and status<>'PENDING') then raise exception 'other consumers marked delivered';end if;
 perform set_config('app.actor_id',md5('venue-basic1user')::uuid::text,true);dto:=app_private.matching_get();
 if dto->'applications'->0->'table'->>'venueStatus'<>'ASSIGNED' or dto->'applications'->0->'table'->'venue'->>'name'<>'LOCAL TEST basic' then raise exception 'own venue DTO';end if;
 if dto::text ~ 'safe_allergies|verificationNote|reviewUrl|reviewCount|birthYear' then raise exception 'private venue evidence leaked';end if;
 insert into app_private.match_relations(user_low,user_high,reason) values(least(md5('venue-basic1user')::uuid,md5('venue-basic2user')::uuid),greatest(md5('venue-basic1user')::uuid,md5('venue-basic2user')::uuid),'report');
 insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('local-stale-confirmation','TABLE_CONFIRMED',t,'{}');
 perform app_private.venue_tick();if exists(select 1 from app_private.venue_allocations where table_id=t and active) then raise exception 'invalidated stock held';end if;
 -- Process the repair before later match jobs.
 perform app_private.matching_tick();
 foreach cases in array array['price','allergy','unknown','missing','seats','stale'] loop
  s:=pg_temp.venue_fixture('venue-'||cases,case when cases='seats' then 5 else 4 end);select id into t from app_private.dining_tables where slot_id=s;
  payload:=pg_temp.venue_payload(s,cases,case when cases='price' then 35000 else 15000 end,case when cases='seats' then 4 else 6 end);
  if cases in ('allergy','unknown') then update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||jsonb_build_object('allergies',case when cases='allergy' then '새우' else '모름' end) where id=md5('venue-'||cases||'1app')::uuid;end if;
  if cases='missing' then update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot-'avoidedFoods' where id=md5('venue-'||cases||'1app')::uuid;end if;
  perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);perform app_private.operations_venue_create(payload);
  if cases='stale' then update app_private.venue_inventory set verified_at=now()-interval '8 days' where slot_id=s;end if;
  perform app_private.venue_tick();
  if exists(select 1 from app_private.venue_allocations where table_id=t and active) then raise exception 'incompatible allocated %',cases;end if;
  if cases='allergy' then
   payload:=pg_temp.venue_payload(s,'reviewed')||'{"safeAllergies":["  새우  "]}';perform app_private.operations_venue_create(payload);perform app_private.venue_tick();
   if not exists(select 1 from app_private.venue_allocations where table_id=t and active) then raise exception 'exact reviewed allergy not allocated';end if;
  end if;
 end loop;
 s:=pg_temp.venue_fixture('venue-update',5);select id into t from app_private.dining_tables where slot_id=s;
 perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);perform app_private.operations_venue_create(pg_temp.venue_payload(s,'update'));perform app_private.venue_tick();
 select id into alloc from app_private.venue_allocations where table_id=t and active;
 perform set_config('app.actor_id',md5('venue-update1user')::uuid::text,true);
 perform app_private.match_resolve(jsonb_build_object('applicationId',md5('venue-update1app')::uuid,'requestKey',gen_random_uuid(),'action','cancel'));perform app_private.venue_tick();
 if (select id from app_private.venue_allocations where table_id=t and active) is distinct from alloc then raise exception 'valid four consumed stock twice';end if;
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"allergies":"미확인"}' where id=md5('venue-update2app')::uuid;
 insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('local-unsafe-update','TABLE_UPDATED',t,'{}');perform app_private.venue_tick();
 if exists(select 1 from app_private.venue_allocations where table_id=t and active) then raise exception 'unsafe update rolled back release';end if;
 s:=pg_temp.venue_fixture('venue-shared',8);perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);
 perform app_private.operations_venue_create(pg_temp.venue_payload(s,'one-reservation'));perform app_private.venue_tick();
 if (select count(*) from app_private.venue_allocations a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=s and a.active)<>1 then raise exception 'inventory oversold';end if;
 -- Revoke removes visible location immediately, without waiting for a browser/Cron.
 select id into inv from app_private.venue_inventory where slot_id=s;
 perform app_private.operations_venue_revoke(jsonb_build_object('inventoryId',inv));
 if exists(select 1 from app_private.venue_allocations where inventory_id=inv and active) then raise exception 'revoked assignment active';end if;
 payload:=pg_temp.venue_payload(s,'invalid');
 begin perform app_private.operations_venue_create(payload||'{"reservationConfirmed":null}');raise exception 'unconfirmed accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform app_private.operations_venue_create(payload||jsonb_build_object('verifiedAt',now()-interval '8 days'));raise exception 'stale registered';exception when others then if sqlerrm<>'VENUE_VERIFICATION_REQUIRED' then raise;end if;end;
 begin perform app_private.operations_venue_create(payload||'{"rating":3.9}');raise exception 'low review accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 if has_function_privilege('app_member_api','app_private.venue_tick()','EXECUTE') or has_table_privilege('app_member_api','app_private.venue_inventory','INSERT') or has_function_privilege('authenticated','app_private.operations_venue_create(jsonb)','EXECUTE') then raise exception 'venue authority leak';end if;
 if (select count(*) from cron.job where jobname='serendipity-venue-tick' and active)<>1 then raise exception 'venue Cron missing';end if;
end $$;
rollback;
