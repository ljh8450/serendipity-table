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
create function pg_temp.content_fixture(label text,start_delta interval,with_venue boolean default true) returns uuid language plpgsql as $$
declare slot uuid;begin
 slot:=pg_temp.venue_fixture(label);perform app_private.chat_tick();
 if with_venue then perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);perform app_private.operations_venue_create(pg_temp.venue_payload(slot,label));perform app_private.venue_tick();end if;
 update app_private.intake_event_slots set starts_at=clock_timestamp()+start_delta,closes_at=least(closes_at,clock_timestamp()+start_delta-interval '2 minutes'),matches_at=least(matches_at,clock_timestamp()+start_delta-interval '1 minute') where id=slot;
 return slot;end $$;
do $$ declare s uuid;t uuid;r uuid;j uuid;inv uuid;result jsonb;before_n int;i int;
begin
 s:=pg_temp.content_fixture('content-early',interval '24 hours 1 minute');
 perform app_private.content_tick();
 if exists(select 1 from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where t.slot_id=s and j.kind in('D1','START') and j.status<>'WAITING') then raise exception 'early publication';end if;
 s:=pg_temp.content_fixture('content-d1',interval '24 hours');select id into t from app_private.dining_tables where slot_id=s;
 perform app_private.content_tick();
 if not exists(select 1 from app_private.content_jobs where table_id=t and kind='D1' and status='DONE') then
  raise exception 'D1 failed: %',(select jsonb_agg(jsonb_build_object('kind',kind,'error',last_error)) from app_private.content_jobs where table_id=t);end if;
 select id into j from app_private.content_jobs where table_id=t and kind='D1';
 if (select count(*) from app_private.chat_messages where system_key like 'content:'||j::text||':%')<>5 then raise exception 'D1 message count';end if;
 if (select count(*) from app_private.member_notifications where table_id=t and kind='EVENT_REMINDER')<>4 then raise exception 'D1 recipients';end if;
 select count(*) into before_n from app_private.chat_messages;perform app_private.content_tick();
 if (select count(*) from app_private.chat_messages)<>before_n then raise exception 'duplicate content';end if;
 s:=pg_temp.content_fixture('content-start',interval '-1 second');select id into t from app_private.dining_tables where slot_id=s;
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"interests":["film","food","travel"],"traits":["deep","calm"]}' where input->'slotIds' ? s::text;
 perform app_private.content_tick();
 select snapshot into result from app_private.content_jobs where table_id=t and kind='START';
 if jsonb_array_length(result->'topics')<>3 or result->>'game' not like '%패스%' or result->'topics'->>0 not like '%이유%' then raise exception 'missing topics/style/game: %',result;end if;
 if result::text ~ 'onboarding|user_id|birthYear|allergies|preferredTraits' then raise exception 'private snapshot leak';end if;
 if (select count(*) from app_private.content_jobs where table_id=t and kind='D1' and last_error='CONTENT_MISSED_WINDOW')<>1 then raise exception 'late reminder sent';end if;
 s:=pg_temp.content_fixture('content-retry',interval '23 hours',false);select id into t from app_private.dining_tables where slot_id=s;
 insert into app_private.push_subscriptions(user_id,endpoint,p256dh,auth) values(md5('content-retry1user')::uuid,'https://fcm.googleapis.com/send/LOCAL-CONTENT-UNIT','B'||repeat('A',86),repeat('A',22));
 perform app_private.content_tick();
 for i in 1..2 loop update app_private.content_jobs set due_at=clock_timestamp() where table_id=t and kind='D1';perform app_private.content_tick();end loop;
 select id into j from app_private.content_jobs where table_id=t and kind='D1' and status='EXCEPTION' and last_error='CONTENT_VENUE_PENDING';
 if j is null then raise exception 'missing venue retry budget';end if;
 perform set_config('app.actor_id',md5('content-retry1user')::uuid::text,true);
 begin perform app_private.operations_content_get();raise exception 'participant monitor';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.operations_content_retry(jsonb_build_object('jobId',j));raise exception 'participant retry';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);
 perform app_private.operations_venue_create(pg_temp.venue_payload(s,'content-retry'));
 perform app_private.venue_tick();perform app_private.operations_content_retry(jsonb_build_object('jobId',j));perform app_private.content_tick();
 if (select status from app_private.content_jobs where id=j)<>'DONE' then raise exception 'D1 recovery failed';end if;
 if (select count(*) from app_private.push_jobs p join app_private.member_notifications n on n.id=p.notification_id where n.table_id=t and n.kind='EVENT_REMINDER')<>1 then raise exception 'real push queue not linked';end if;
 select inventory_id into inv from app_private.venue_allocations where table_id=t and active;
 perform app_private.operations_venue_revoke(jsonb_build_object('inventoryId',inv));perform app_private.content_tick();
 if not exists(select 1 from app_private.content_jobs where table_id=t and kind='GUIDE' and status='DONE' and snapshot::text like '%장소가 회수%') then raise exception 'withdrawal guide missing';end if;
 perform app_private.operations_venue_create(pg_temp.venue_payload(s,'content-new-location'));perform app_private.venue_tick();perform app_private.content_tick();
 if (select count(*) from app_private.content_jobs where table_id=t and kind='GUIDE' and status='DONE')<>4 then raise exception 'location guide revision lost';end if;
 perform set_config('app.actor_id',md5('content-retry1user')::uuid::text,true);
 perform app_private.match_resolve(jsonb_build_object('applicationId',md5('content-retry1app')::uuid,'requestKey',gen_random_uuid(),'action','cancel'));
 perform app_private.content_tick();
 if (select status from app_private.content_jobs where table_id=t and kind='START')<>'CANCELED' then raise exception 'cancel did not suppress content';end if;
 if jsonb_array_length(app_private.notifications_get()->'notifications')<>0 then raise exception 'old notices visible';end if;
 s:=pg_temp.content_fixture('content-missed',interval '-3 hours');select id into t from app_private.dining_tables where slot_id=s;perform app_private.content_tick();
 select id into j from app_private.content_jobs where table_id=t and kind='START' and last_error='CONTENT_MISSED_WINDOW';
 if j is null then raise exception 'missed start published';end if;
 perform set_config('app.actor_id',md5('venue-operator')::uuid::text,true);
 begin perform app_private.operations_content_retry(jsonb_build_object('jobId',j));raise exception 'missed window retry allowed';exception when others then if sqlerrm<>'JOB_CONFLICT' then raise;end if;end;
 if app_private.operations_content_get()::text ~ 'snapshot|topics|onboarding|p256dh|reservation_name' then raise exception 'monitor leak';end if;
 s:=pg_temp.content_fixture('content-long',interval '1 hour',false);select id into t from app_private.dining_tables where slot_id=s;
 perform app_private.operations_venue_create(pg_temp.venue_payload(s,'content-long')||jsonb_build_object('name',repeat('N',500),'address',repeat('A',500),'reservationName',repeat('R',500)));
 perform app_private.venue_tick();perform app_private.content_tick();
 if not exists(select 1 from app_private.content_jobs where table_id=t and kind='D1' and status='DONE') then raise exception 'valid long venue failed';end if;
 if exists(select 1 from app_private.chat_messages m join app_private.chat_rooms cr on cr.id=m.room_id where cr.table_id=t and length(m.body)>1000) then raise exception 'message overflow';end if;
 s:=pg_temp.content_fixture('content-room',interval '1 hour');select id into t from app_private.dining_tables where slot_id=s;
 delete from app_private.chat_rooms where table_id=t;perform app_private.content_tick();
 if not exists(select 1 from app_private.content_jobs where table_id=t and kind='D1' and last_error='CONTENT_ROOM_PENDING') then raise exception 'room pending lost';end if;
 perform app_private.chat_apply(t,gen_random_uuid(),'TABLE_CONFIRMED');
 update app_private.content_jobs set due_at=clock_timestamp() where table_id=t;perform app_private.content_tick();
 if not exists(select 1 from app_private.content_jobs where table_id=t and kind='D1' and status='DONE') then raise exception 'room recovery failed';end if;
 if has_function_privilege('app_member_api','app_private.content_tick()','EXECUTE') or has_function_privilege('app_member_api','app_private.content_topics(uuid)','EXECUTE') or has_table_privilege('app_member_api','app_private.content_jobs','SELECT') then raise exception 'internal access';end if;
end $$;
rollback;
