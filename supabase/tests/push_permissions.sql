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

create function pg_temp.chat_fixture(label text,num int default 4) returns uuid language plpgsql as $$
declare slot uuid;room_uuid uuid;
begin slot:=pg_temp.match_fixture(label,num);perform app_private.matching_tick();perform app_private.chat_tick();
 select r.id into room_uuid from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=slot order by r.id limit 1;return room_uuid;end $$;
create function pg_temp.chat_read(room_uuid uuid,label text,i int default 1,before_id text default null) returns jsonb language plpgsql as $$
begin perform set_config('app.actor_id',md5(label||i||'user')::uuid::text,true);return app_private.chat_get(jsonb_build_object('roomId',room_uuid,'before',before_id));end $$;
create function pg_temp.chat_message(room_uuid uuid,label text,i int default 1,body text default '안녕하세요',req uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
begin perform set_config('app.actor_id',md5(label||i||'user')::uuid::text,true);return app_private.chat_send(jsonb_build_object('roomId',room_uuid,'requestKey',req,'body',body));end $$;
do $$ declare actor uuid:=md5('push-basic1user')::uuid; other uuid:=md5('push-basic2user')::uuid; endpoint text:='https://fcm.googleapis.com/fcm/send/LOCAL-UNIT-ONLY';sub jsonb;job jsonb;notice uuid;room uuid;i int;
begin
 room:=pg_temp.chat_fixture('push-basic');
 insert into app_private.push_config(id,public_key) values(true,'B'||repeat('A',86)) on conflict do nothing;
 perform set_config('app.actor_id',actor::text,true);
 sub:=jsonb_build_object('subscription',jsonb_build_object('endpoint',endpoint,'expirationTime',null,'keys',jsonb_build_object('p256dh','B'||repeat('A',86),'auth',repeat('A',22))));
 perform app_private.push_subscribe(sub);perform app_private.push_subscribe(sub);
 if (app_private.push_get()->>'activeDevices')::int<>1 then raise exception 'duplicate subscription';end if;
 if app_private.push_get()::text ~ 'endpoint|p256dh|auth' then raise exception 'subscription leak';end if;
 perform set_config('app.actor_id',other::text,true);
 begin perform app_private.push_subscribe(sub);raise exception 'subscription stolen';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 perform set_config('app.actor_id',actor::text,true);
 begin perform app_private.push_subscribe(jsonb_set(sub,'{subscription,endpoint}','"https://localhost/private"'));raise exception 'SSRF accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 notice:=(app_private.push_test()->>'notificationId')::uuid;
 begin perform app_private.push_test();raise exception 'test spam';exception when others then if sqlerrm<>'PUSH_RATE_LIMIT' then raise;end if;end;
 if (select count(*) from app_private.push_jobs where notification_id=notice)<>1 then raise exception 'queue missing';end if;
 job:=app_private.push_claim();
 if job->>'notificationId'<>notice::text or app_private.push_claim() is not null then raise exception 'double claim';end if;
 if app_private.push_finish((job->>'id')::uuid,gen_random_uuid(),201) then raise exception 'foreign lease';end if;
 perform app_private.push_finish((job->>'id')::uuid,(job->>'token')::uuid,500);
 if (select status from app_private.push_jobs where notification_id=notice)<>'PENDING' then raise exception 'retry missing';end if;
 update app_private.push_jobs set due_at=clock_timestamp() where notification_id=notice;
 job:=app_private.push_claim();perform app_private.push_finish((job->>'id')::uuid,(job->>'token')::uuid,410);
 if (select enabled from app_private.push_subscriptions where user_id=actor limit 1) then raise exception 'expired subscription active';end if;
 perform app_private.push_subscribe(sub);
 insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id) select actor,'push-revoke','CHAT_MESSAGE',ta.table_id,ta.application_id from app_private.table_assignments ta where ta.user_id=actor;
 update app_private.table_assignments set active=false where user_id=actor;
 if app_private.push_claim() is not null then raise exception 'revoked notification sent';end if;
 insert into app_private.member_notifications(user_id,event_key,kind) values(actor,'lease-exhausted','PUSH_TEST') returning id into notice;
 update app_private.push_jobs set status='RUNNING',attempts=3,lease_until=clock_timestamp()-interval '1 second',token=gen_random_uuid() where notification_id=notice;
 job:=app_private.push_claim();
 if job is not null or (select status from app_private.push_jobs where notification_id=notice)<>'EXCEPTION' then raise exception 'lease exhaustion';end if;
 begin perform app_private.operations_push_get();raise exception 'participant monitor';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 update app_private.member_accounts set role='operator' where user_id=actor;
 if app_private.operations_push_get()::text ~ 'endpoint|p256dh|auth|subscription' then raise exception 'monitor leak';end if;
 perform app_private.operations_push_retry(jsonb_build_object('jobId',(select id from app_private.push_jobs where notification_id=notice)));
 update app_private.member_accounts set restricted=true where user_id=actor;
 if app_private.push_claim() is not null then raise exception 'restricted push';end if;
 update app_private.member_accounts set restricted=false where user_id=actor;
 insert into app_private.member_notifications(user_id,event_key,kind) values(actor,'retry-limit','PUSH_TEST') returning id into notice;
 for i in 1..3 loop
  update app_private.push_jobs set due_at=clock_timestamp() where notification_id=notice;
  job:=app_private.push_claim();perform app_private.push_finish((job->>'id')::uuid,(job->>'token')::uuid,0);
 end loop;
 if (select status from app_private.push_jobs where notification_id=notice)<>'EXCEPTION' then raise exception 'retry limit';end if;
 perform app_private.push_unsubscribe(jsonb_build_object('endpoint',endpoint));perform app_private.push_unsubscribe(jsonb_build_object('endpoint',endpoint));
 for i in 1..10 loop perform app_private.push_subscribe(jsonb_set(sub,'{subscription,endpoint}',to_jsonb(endpoint||i::text)));end loop;
 begin perform app_private.push_subscribe(jsonb_set(sub,'{subscription,endpoint}',to_jsonb(endpoint||'11')));raise exception 'device cap bypass';exception when others then if sqlerrm<>'PUSH_DEVICE_LIMIT' then raise;end if;end;
 perform app_private.push_unsubscribe(jsonb_build_object('endpoint',endpoint||'1'));
 perform app_private.push_subscribe(jsonb_set(sub,'{subscription,endpoint}',to_jsonb(endpoint||'11')));
 if (app_private.push_get()->>'activeDevices')::int<>10 then raise exception 'disabled device did not release capacity';end if;
 if has_function_privilege('app_member_api','app_private.push_claim()','EXECUTE') or has_table_privilege('app_member_api','app_private.push_subscriptions','SELECT') then raise exception 'internal access';end if;
end $$;
rollback;
