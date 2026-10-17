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
create function pg_temp.next_people(label text,source_label text,n int) returns uuid language plpgsql as $$
declare s uuid;i int;begin
 s:=pg_temp.match_fixture(label,n);
 update app_private.intake_event_slots set starts_at=clock_timestamp()+interval '14 days' where id=s;
 for i in 1..least(n,4) loop
  update app_private.intake_applications set user_id=md5(source_label||i||'user')::uuid where id=md5(label||i||'app')::uuid;
  update app_private.payment_attempts set user_id=md5(source_label||i||'user')::uuid where application_id=md5(label||i||'app')::uuid;
 end loop;
 update app_private.intake_applications set onboarding_snapshot=jsonb_set(onboarding_snapshot,'{gender}','"male"') where input->'slotIds' ? s::text;
 return s;
end $$;
create function pg_temp.preference(label text,who int,peer int,v text,rev int,k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare a uuid;b uuid;begin
 perform set_config('app.actor_id',md5(label||who||'user')::uuid::text,true);
 select id into a from app_private.table_assignments where application_id=md5(label||who||'app')::uuid;
 select id into b from app_private.table_assignments where application_id=md5(label||peer||'app')::uuid;
 return app_private.preferences_save(jsonb_build_object('assignmentId',a,'peerId',b,'value',v,'revision',rev,'requestKey',k));
end $$;
do $$ declare s uuid;n uuid;t uuid;k uuid:=gen_random_uuid();dto jsonb;peer int;a uuid;b uuid;
begin
 s:=pg_temp.person_fixture('person-basic');
 if (select count(*) from app_private.actual_meetings where table_id in(select id from app_private.dining_tables where slot_id=s))<>6 then raise exception 'actual encounter count';end if;
 update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('person-basic4app')::uuid;
 if app_private.match_pair_met(md5('person-basic1user')::uuid,md5('person-basic4user')::uuid) then raise exception 'noshow counted';end if;
 dto:=pg_temp.preference('person-basic',1,2,'LIKE',0,k);
 perform pg_temp.preference('person-basic',1,2,'LIKE',0,k);
 begin perform pg_temp.preference('person-basic',1,2,'AVOID',0,k);raise exception 'changed replay';exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 begin perform pg_temp.preference('person-basic',1,2,'AVOID',0);raise exception 'stale revision';exception when others then if sqlerrm<>'PREFERENCE_CONFLICT' then raise;end if;end;
 begin perform pg_temp.preference('person-basic',1,1,'AVOID',0);raise exception 'self choice';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform pg_temp.preference('person-basic',1,4,'AVOID',0);raise exception 'noshow choice';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 if dto::text ~ 'user_id|target_user|birthYear|instagram|onboarding|requestKey' then raise exception 'private DTO leak';end if;
 perform set_config('app.actor_id',md5('person-basic2user')::uuid::text,true);dto:=app_private.preferences_get();
 if exists(select 1 from jsonb_array_elements(dto->'events') e,jsonb_array_elements(e->'peers') p where p->>'value'<>'NEUTRAL') then raise exception 'peer choice leaked';end if;
 perform pg_temp.preference('person-basic',2,1,'AVOID',0);
 perform pg_temp.preference('person-basic',1,2,'NEUTRAL',1);
 if not app_private.match_pair_blocked(md5('person-basic1user')::uuid,md5('person-basic2user')::uuid) then raise exception 'neutral cleared peer avoid';end if;
 perform pg_temp.preference('person-basic',2,1,'NEUTRAL',1);
 n:=pg_temp.next_people('person-next','person-basic',4);perform app_private.matching_tick();
 if (select count(*) from app_private.dining_tables where slot_id=n and status='CONFIRMED')<>1 then raise exception 'neutral next match';end if;
 select id into t from app_private.dining_tables where slot_id=n and status='CONFIRMED';
 k:=gen_random_uuid();perform pg_temp.preference('person-basic',1,2,'AVOID',2,k);perform pg_temp.preference('person-basic',1,2,'AVOID',2,k);
 if (select status from app_private.dining_tables where id=t)<>'INVALIDATED' then raise exception 'future unsafe kept';end if;
 if (select count(*) from app_private.match_outbox where aggregate_id=t and event_type='TABLE_INVALIDATED')<>1 then raise exception 'repair duplicate';end if;
 if (select count(*) from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id where dt.slot_id=s and ta.active)<>4 then raise exception 'past table lost';end if;
 perform app_private.matching_tick();
 if exists(select 1 from app_private.dining_tables where slot_id=n and status='CONFIRMED') then raise exception 'avoid ignored in next match';end if;
 perform pg_temp.preference('person-basic',1,2,'NEUTRAL',3);
 perform pg_temp.preference('person-basic',1,2,'AVOID',2,k);
 if app_private.match_pair_blocked(md5('person-basic1user')::uuid,md5('person-basic2user')::uuid) then raise exception 'old replay reapplied';end if;
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours 7 days',opens_at=clock_timestamp()-interval '9 days',closes_at=clock_timestamp()-interval '8 days',matches_at=clock_timestamp()-interval '8 days' where id=s;
 begin perform pg_temp.preference('person-basic',1,2,'LIKE',4);raise exception 'expired accepted';exception when others then if sqlerrm<>'PREFERENCE_CLOSED' then raise;end if;end;
 update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('person-basic2app')::uuid;
 begin perform pg_temp.preference('person-basic',1,2,'AVOID',2,k);raise exception 'revoked replay';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 -- Choose a previously separated real pair; equal base profiles make explicit affinity observable.
 s:=pg_temp.person_fixture('person-like');n:=pg_temp.next_people('person-like-next','person-like',8);perform app_private.matching_tick();
 select table_id into a from app_private.table_assignments where application_id=md5('person-like-next1app')::uuid;
 select i into peer from generate_series(2,4) i where (select table_id from app_private.table_assignments where application_id=md5('person-like-next'||i||'app')::uuid)<>a limit 1;
 if peer is null then raise exception 'new people not distributed';end if;
 perform pg_temp.preference('person-like',1,peer,'LIKE',0);
 delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=n);
 delete from app_private.table_assignments where table_id in(select id from app_private.dining_tables where slot_id=n);
 delete from app_private.dining_tables where slot_id=n;
 update app_private.intake_applications set matching_status='WAITING' where input->'slotIds' ? n::text;
 update app_private.match_jobs set status='QUEUED',due_at=clock_timestamp(),attempts=0 where slot_id=n;
 perform app_private.matching_tick();
 select table_id into a from app_private.table_assignments where application_id=md5('person-like-next1app')::uuid and active;
 select table_id into b from app_private.table_assignments where application_id=md5('person-like-next'||peer||'app')::uuid and active;
 if a is distinct from b or a is null then raise exception 'explicit like tie ignored';end if;
 update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('person-like'||peer||'app')::uuid;
 if app_private.match_pair_liked(md5('person-like1user')::uuid,md5('person-like'||peer||'user')::uuid) or app_private.match_pair_met(md5('person-like1user')::uuid,md5('person-like'||peer||'user')::uuid) then raise exception 'corrected attendance evidence retained';end if;
 if has_table_privilege('app_member_api','app_private.person_preferences','SELECT') or has_table_privilege('authenticated','app_private.actual_meetings','SELECT') or has_function_privilege('app_member_api','app_private.preferences_repair(uuid)','EXECUTE') then raise exception 'grants leaked';end if;
end $$;
do $$ declare source_slot uuid;next_slot uuid;peer uuid;op uuid:=md5('person-restore-op')::uuid;
begin
 source_slot:=pg_temp.person_fixture('person-restore');
 perform pg_temp.preference('person-restore',1,2,'AVOID',0);
 select id into peer from app_private.table_assignments where application_id=md5('person-restore2app')::uuid;
 update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('person-restore2app')::uuid;
 insert into app_private.attendance_records(assignment_id,closed_at,review_status) values(peer,clock_timestamp(),'NO_SHOW');
 next_slot:=pg_temp.next_people('person-restore-next','person-restore',4);perform app_private.matching_tick();
 if (select count(*) from app_private.dining_tables where slot_id=next_slot and status='CONFIRMED')<>1 then raise exception 'inactive avoid should allow';end if;
 insert into auth.users(id) values(op);insert into app_private.member_accounts(user_id,role) values(op,'operator');
 perform set_config('app.actor_id',op::text,true);
 perform app_private.operations_attendance_review(jsonb_build_object('assignmentId',peer,'requestKey',gen_random_uuid(),'outcome','ATTENDED','reason','local attendance restoration'));
 if not app_private.match_pair_blocked(md5('person-restore1user')::uuid,md5('person-restore2user')::uuid) then raise exception 'restored avoid lost';end if;
 if exists(select 1 from app_private.dining_tables where slot_id=next_slot and status='CONFIRMED') then raise exception 'restored avoid left invalid future table';end if;
 if (select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=source_slot and a.active)<>4 then raise exception 'restoration revoked source';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('person-like1user')::uuid::text,true);
select app_private.preferences_get();
reset role;
rollback;
