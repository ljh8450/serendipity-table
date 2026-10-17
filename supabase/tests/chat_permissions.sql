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
do $$ declare r uuid;r2 uuid;t uuid;k uuid:=gen_random_uuid();result jsonb;dto jsonb;older jsonb;i int;event_uuid uuid;label text;
begin
 r:=pg_temp.chat_fixture('chat-basic');perform app_private.chat_tick();
 if (select count(*) from app_private.chat_rooms where id=r)<>1 or (select count(*) from app_private.chat_messages where room_id=r and system_key='welcome')<>1 then raise exception 'duplicate room/welcome';end if;
 if jsonb_array_length(pg_temp.chat_read(r,'chat-basic')->'members')<>4 then raise exception 'member sync';end if;
 result:=pg_temp.chat_message(r,'chat-basic',1,'<img src=x onerror=alert(1)>',k);
 if pg_temp.chat_message(r,'chat-basic',1,'<img src=x onerror=alert(1)>',k)<>result then raise exception 'duplicate replay';end if;
 begin perform pg_temp.chat_message(r,'chat-basic',1,'changed',k);raise exception 'changed key accepted';exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 dto:=pg_temp.chat_read(r,'chat-basic',2);
 if jsonb_array_length(dto->'messages')<>2 or (dto->'messages'->1->>'mine')::boolean then raise exception 'other member message';end if;
 if dto::text ~ 'userId|user_id|member_id|instagram|birthYear|onboarding|requestKey|request_key' then raise exception 'internal chat identity leak';end if;
 if dto->'messages'->0->'mine'<>'false'::jsonb then raise exception 'system mine is not boolean false';end if;
 for i in 2..10 loop perform pg_temp.chat_message(r,'chat-basic',1,'rate '||i);end loop;
 begin perform pg_temp.chat_message(r,'chat-basic',1,'over limit');raise exception 'rate limit bypass';exception when others then if sqlerrm<>'CHAT_RATE_LIMIT' then raise;end if;end;
 if pg_temp.chat_message(r,'chat-basic',1,'<img src=x onerror=alert(1)>',k)<>result then raise exception 'rate-limited replay rejected';end if;
 begin perform pg_temp.chat_message(r,'chat-basic',2,'  ');raise exception 'blank accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform pg_temp.chat_message(r,'chat-basic',2,repeat('x',1001));raise exception 'oversize accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 r2:=pg_temp.chat_fixture('chat-other');
 begin perform pg_temp.chat_read(r2,'chat-basic');raise exception 'cross room read';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform pg_temp.chat_message(r2,'chat-basic');raise exception 'cross room send';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 insert into app_private.chat_messages(room_id,kind,system_key,body) select r,'SYSTEM','fixture:'||g,'LOCAL PAGE '||g from generate_series(1,65) g;
 dto:=pg_temp.chat_read(r,'chat-basic');older:=pg_temp.chat_read(r,'chat-basic',1,dto->>'nextBefore');
 if jsonb_array_length(dto->'messages')<>50 or dto->>'nextBefore' is null or jsonb_array_length(older->'messages')<>26 or older->>'nextBefore' is not null then raise exception 'pagination gaps';end if;
 if exists(select 1 from jsonb_array_elements(dto->'messages') a join jsonb_array_elements(older->'messages') b on a->>'id'=b->>'id') then raise exception 'pagination overlap';end if;
 begin perform pg_temp.chat_read(r,'chat-basic',1,'9999999999999999999');raise exception 'overflow cursor';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 -- A five-person table keeps its room after cancellation, but the leaver is denied before Cron.
 r:=pg_temp.chat_fixture('chat-cancel',5);select table_id into t from app_private.chat_rooms where id=r;
 result:=pg_temp.chat_message(r,'chat-cancel',1,'before cancel',k);
 perform app_private.match_resolve(jsonb_build_object('applicationId',md5('chat-cancel1app')::uuid,'requestKey',gen_random_uuid(),'action','cancel'));
 begin perform pg_temp.chat_read(r,'chat-cancel',1);raise exception 'canceled read before Cron';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform pg_temp.chat_message(r,'chat-cancel',1,'before cancel',k);raise exception 'canceled replay before Cron';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 if jsonb_array_length(pg_temp.chat_read(r,'chat-cancel',2)->'members')<>4 then raise exception 'live roster stale';end if;
 perform app_private.chat_tick();perform app_private.chat_tick();
 if (select status from app_private.chat_rooms where id=r)<>'OPEN' or (select count(*) from app_private.chat_members where room_id=r and active)<>4 then raise exception 'valid four room lost';end if;
 if (select count(*) from app_private.chat_messages where room_id=r and system_key like 'event:%')<>1 then raise exception 'duplicate update notice';end if;
 -- Immediate relationship separation, then stale confirmation replay cannot reopen the room.
 insert into app_private.match_relations(user_low,user_high,reason) values(least(md5('chat-cancel2user')::uuid,md5('chat-cancel3user')::uuid),greatest(md5('chat-cancel2user')::uuid,md5('chat-cancel3user')::uuid),'report');
 begin perform pg_temp.chat_read(r,'chat-cancel',2);raise exception 'report separation delayed';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('local-stale-chat','TABLE_CONFIRMED',t,'{}');perform app_private.chat_tick();
 if (select status from app_private.chat_rooms where id=r)<>'CLOSED' then raise exception 'stale event reopened room';end if;
 perform app_private.matching_tick();
 -- Consumer exception budget and operator retry.
 label:='chat-invalid';perform pg_temp.match_fixture(label,4);perform app_private.matching_tick();
 select id into t from app_private.dining_tables where slot_id=md5(label||'slot')::uuid;
 update app_private.table_assignments set active=false where application_id=md5(label||'1app')::uuid;
 for i in 1..3 loop update app_private.chat_receipts set due_at=clock_timestamp() where status='QUEUED';perform app_private.chat_tick();end loop;
 select c.event_id into event_uuid from app_private.chat_receipts c join app_private.match_outbox o on o.id=c.event_id where o.aggregate_id=t and c.status='EXCEPTION';
 if event_uuid is null then raise exception 'missing final exception';end if;
 insert into auth.users(id) values(md5('chat-operator')::uuid);insert into app_private.member_accounts(user_id,role) values(md5('chat-operator')::uuid,'operator');
 update app_private.table_assignments set active=true where application_id=md5(label||'1app')::uuid;
 perform set_config('app.actor_id',md5('chat-operator')::uuid::text,true);dto:=app_private.operations_chat_retry(jsonb_build_object('eventId',event_uuid));perform app_private.chat_tick();
 if not exists(select 1 from app_private.chat_rooms where table_id=t and status='OPEN') then raise exception 'operator repair failed';end if;
 if dto::text like '%onerror%' or dto::text like '%before cancel%' then raise exception 'operator raw conversation leak';end if;
 if exists(select 1 from app_private.match_outbox where status<>'PENDING') then raise exception 'global outbox prematurely delivered';end if;
 if has_table_privilege('app_member_api','app_private.chat_messages','INSERT') or has_function_privilege('app_member_api','app_private.chat_tick()','EXECUTE') or has_function_privilege('authenticated','app_private.chat_get(jsonb)','EXECUTE') then raise exception 'chat grants leaked';end if;
 if (select count(*) from cron.job where jobname='serendipity-chat-tick' and active)<>1 then raise exception 'chat Cron missing';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('chat-basic1user')::uuid::text,true);
do $$ declare r uuid;dto jsonb;begin dto:=app_private.matching_get();r:=(dto->'applications'->0->'table'->'chat'->>'roomId')::uuid;if r is null then raise exception 'own room capability';end if;perform app_private.chat_get(jsonb_build_object('roomId',r,'before',null));end $$;
reset role;
rollback;
