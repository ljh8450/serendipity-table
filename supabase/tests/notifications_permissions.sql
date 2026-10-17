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
do $$ declare r uuid; n uuid; dto jsonb; before_count int;
begin
 r:=pg_temp.chat_fixture('notifications-basic');
 perform app_private.notifications_tick();
 select count(*) into before_count from app_private.member_notifications;
 perform app_private.notifications_tick();
 if (select count(*) from app_private.member_notifications)<>before_count then raise exception 'duplicate event notifications';end if;
 perform set_config('app.actor_id',md5('notifications-basic1user')::uuid::text,true);
 dto:=app_private.notifications_get();
 if (dto->>'unreadCount')::int<>1 then raise exception 'confirmation missing';end if;
 insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
 select ta.user_id,'venue:missing','VENUE_ASSIGNED',ta.table_id,ta.application_id from app_private.table_assignments ta
 where ta.user_id=md5('notifications-basic1user')::uuid;
 if jsonb_array_length(app_private.notifications_get()->'notifications')<>1 then raise exception 'released venue notice visible';end if;
 n:=(dto->'notifications'->0->>'id')::uuid;
 perform app_private.notifications_read(jsonb_build_object('id',n));
 perform app_private.notifications_read(jsonb_build_object('id',n));
 if (app_private.notifications_get()->>'unreadCount')::int<>0 then raise exception 'read failed';end if;
 perform set_config('app.actor_id',md5('notifications-basic2user')::uuid::text,true);
 begin perform app_private.notifications_read(jsonb_build_object('id',n));raise exception 'foreign read accepted';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 perform pg_temp.chat_message(r,'notifications-basic',1,'PRIVATE CHAT MUST NOT LEAK');
 perform set_config('app.actor_id',md5('notifications-basic2user')::uuid::text,true);
 dto:=app_private.notifications_get();
 if jsonb_array_length(dto->'notifications')<>2 then raise exception 'chat notification missing';end if;
 if dto::text ~ 'PRIVATE CHAT|user_id|application_id|table_id|event_key|onboarding' then raise exception 'notification privacy leak';end if;
 perform set_config('app.actor_id',md5('notifications-basic1user')::uuid::text,true);
 if jsonb_array_length(app_private.notifications_get()->'notifications')<>1 then raise exception 'sender notified itself';end if;
 update app_private.table_assignments set active=false where user_id=md5('notifications-basic2user')::uuid;
 perform set_config('app.actor_id',md5('notifications-basic2user')::uuid::text,true);
 if jsonb_array_length(app_private.notifications_get()->'notifications')<>0 then raise exception 'revoked notices visible';end if;
 begin perform app_private.notifications_read(jsonb_build_object('id','not-a-uuid'));raise exception 'invalid id accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 perform pg_temp.match_fixture('notifications-failure',3);perform app_private.matching_tick();perform app_private.notifications_tick();
 perform set_config('app.actor_id',md5('notifications-failure1user')::uuid::text,true);
 dto:=app_private.notifications_get();
 if jsonb_array_length(dto->'notifications')<>1 or dto->'notifications'->0->>'kind'<>'ALTERNATIVE_OFFERED' then raise exception 'failure guidance missing';end if;
 update app_private.dining_tables set status='INVALIDATED' where id=(select table_id from app_private.chat_rooms where id=r);
 insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) select 'notification-invalidation-test','TABLE_INVALIDATED',table_id,'{}' from app_private.chat_rooms where id=r;
 perform app_private.notifications_tick();
 perform set_config('app.actor_id',md5('notifications-basic1user')::uuid::text,true);
 dto:=app_private.notifications_get();
 if jsonb_array_length(dto->'notifications')<>1 or dto->'notifications'->0->>'kind'<>'TABLE_INVALIDATED' then raise exception 'invalidation guidance missing';end if;
 if has_table_privilege('app_member_api','app_private.member_notifications','SELECT') then raise exception 'direct table access';end if;
 if has_function_privilege('app_member_api','app_private.notifications_tick()','EXECUTE') then raise exception 'public worker';end if;
end $$;
rollback;
