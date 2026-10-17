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
create function pg_temp.safety(label text,who int,peer int,kind text,k uuid default gen_random_uuid(),note text default 'PRIVATE REPORT TEST CONTENT') returns jsonb language plpgsql as $$
declare a uuid;b uuid;begin
 perform set_config('app.actor_id',md5(label||who||'user')::uuid::text,true);
 select id into a from app_private.table_assignments where application_id=md5(label||who||'app')::uuid;
 select id into b from app_private.table_assignments where application_id=md5(label||peer||'app')::uuid;
 return app_private.safety_submit(jsonb_build_object('assignmentId',a,'peerId',b,'kind',kind,'requestKey',k)||case when kind='REPORT' then jsonb_build_object('category','HARASSMENT','details',note) else '{}'::jsonb end);
end $$;
do $$ declare s uuid;n uuid;a uuid;b uuid;room uuid;k uuid:=gen_random_uuid();report uuid;op uuid:=md5('safety-op')::uuid;plain uuid:=md5('safety-plain-op')::uuid;dto jsonb;key uuid:=gen_random_uuid();
begin
 s:=pg_temp.match_fixture('safe-basic',4);perform app_private.matching_tick();perform app_private.chat_tick();
 select id,table_id into a,b from app_private.table_assignments where application_id=md5('safe-basic1app')::uuid;
 select id into room from app_private.chat_rooms where table_id=b;
 dto:=pg_temp.safety('safe-basic',1,2,'REPORT',k);
 perform pg_temp.safety('safe-basic',1,2,'REPORT',k);
 if (select count(*) from app_private.safety_reports where reporter_id=md5('safe-basic1user')::uuid)<>1 then raise exception 'duplicate report';end if;
 if dto::text~'PRIVATE REPORT|target_id|user_id|details|reason' then raise exception 'own raw leak';end if;
 begin perform pg_temp.safety('safe-basic',1,2,'REPORT',k,'CHANGED PRIVATE REPORT CONTENT');raise exception 'changed key accepted';exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 begin perform pg_temp.safety('safe-basic',1,1,'BLOCK');raise exception 'self block';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform pg_temp.safety('safe-basic',1,3,'REPORT',gen_random_uuid(),'short');raise exception 'short accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 if exists(select 1 from app_private.table_assignments where table_id=b and active) then raise exception 'future unsafe source left active';end if;
 if (select count(*) from app_private.match_outbox where aggregate_id=b and event_type='TABLE_INVALIDATED')<>1 then raise exception 'duplicate repair';end if;
 begin perform app_private.chat_get(jsonb_build_object('roomId',room,'before',null));raise exception 'chat not revoked';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 perform set_config('app.actor_id',md5('safe-basic2user')::uuid::text,true);dto:=app_private.safety_get();
 if exists(select 1 from jsonb_array_elements(dto->'contexts') c,jsonb_array_elements(c->'peers') p where (p->>'separated')::boolean) then raise exception 'peer exclusion leaked';end if;
 if jsonb_array_length(dto->'reports')<>0 or dto::text~'PRIVATE REPORT' then raise exception 'target read report';end if;
 perform pg_temp.safety('safe-basic',2,1,'BLOCK');
 if (select count(*) from app_private.safety_exclusions where user_low=least(md5('safe-basic1user')::uuid,md5('safe-basic2user')::uuid))<>1 then raise exception 'pair duplicate';end if;
 insert into auth.users(id) values(op),(plain);insert into app_private.member_accounts(user_id,role) values(op,'operator'),(plain,'operator');insert into app_private.safety_reviewers values(op);
 select id into report from app_private.safety_reports where reporter_id=md5('safe-basic1user')::uuid;
 perform set_config('app.actor_id',plain::text,true);dto:=app_private.operations_safety_get();
 if (dto->>'canReview')::boolean or dto::text~'PRIVATE REPORT|reporter|target|details|birthYear|userId' then raise exception 'plain operator leak';end if;
 begin perform app_private.operations_safety_detail(jsonb_build_object('caseType','REPORT','caseId',report));raise exception 'plain detail';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 perform set_config('app.actor_id',op::text,true);dto:=app_private.operations_safety_detail(jsonb_build_object('caseType','REPORT','caseId',report));
 if dto->>'details'<>'PRIVATE REPORT TEST CONTENT' or dto::text~'reporter|target_id|user_id|birthYear' then raise exception 'review DTO';end if;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',key,'revision',0,'action','WARN','reason','local warning verified'));
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',key,'revision',0,'action','WARN','reason','local warning verified'));
 if (select count(*) from app_private.safety_actions where target_id=md5('safe-basic2user')::uuid)<>1 then raise exception 'duplicate warning';end if;
 if not app_private.safety_allowed(md5('safe-basic2user')::uuid) then raise exception 'warning bans';end if;
 begin perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',gen_random_uuid(),'revision',0,'action','RESTRICT','reason','local stale review'));raise exception 'stale action accepted';exception when others then if sqlerrm<>'SAFETY_CONFLICT' then raise;end if;end;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',gen_random_uuid(),'revision',1,'action','RESTRICT','reason','local restriction verified'));
 if app_private.safety_allowed(md5('safe-basic2user')::uuid) then raise exception 'restriction missing';end if;
 if (select resolution_reason from app_private.intake_applications where id=md5('safe-basic2app')::uuid)<>'safety_hold' then raise exception 'money hold missing';end if;
 perform set_config('app.actor_id',md5('safe-basic2user')::uuid::text,true);dto:=app_private.matching_get();
 if not exists(select 1 from jsonb_array_elements(dto->'applications') j where (j->>'canResolve')::boolean and (j->>'canRefund')::boolean and jsonb_array_length(j->'alternatives')=0) then raise exception 'hold resolution not available';end if;
 -- Restricted users can still report using historical assignment authority.
 perform pg_temp.safety('safe-basic',2,3,'REPORT');
 begin
  insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
  select gen_random_uuid(),md5('safe-basic2user')::uuid,gen_random_uuid(),input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,'PENDING' from app_private.intake_applications where id=md5('safe-basic1app')::uuid;
  raise exception 'restricted new application';exception when others then if sqlerrm<>'PARTICIPATION_RESTRICTED' then raise;end if;
 end;
 perform app_private.mock_refund(jsonb_build_object('applicationId',md5('safe-basic2app')::uuid,'requestKey',gen_random_uuid(),'outcome','success'));
 if (select payment_status from app_private.intake_applications where id=md5('safe-basic2app')::uuid)<>'REFUNDED' then raise exception 'restricted refund blocked';end if;
 if not exists(select 1 from app_private.refund_attempts where application_id=md5('safe-basic2app')::uuid and reason='safety_hold') then raise exception 'refund audit cause';end if;
 perform set_config('app.actor_id',op::text,true);
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',gen_random_uuid(),'revision',2,'action','BAN','reason','local permanent restriction'));
 begin perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',gen_random_uuid(),'revision',3,'action','RESTRICT','reason','cannot weaken permanent'));raise exception 'ban weakened';exception when others then if sqlerrm<>'SAFETY_CONFLICT' then raise;end if;end;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',gen_random_uuid(),'revision',3,'action','RESTORE','reason','local restoration verified'));
 if not app_private.safety_allowed(md5('safe-basic2user')::uuid) or not app_private.match_pair_blocked(md5('safe-basic1user')::uuid,md5('safe-basic2user')::uuid) then raise exception 'restore removed pair exclusion';end if;
 if (select payment_status from app_private.intake_applications where id=md5('safe-basic2app')::uuid)<>'REFUNDED' then raise exception 'restore resurrected money';end if;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',report,'requestKey',gen_random_uuid(),'revision',4,'action','DISMISS','reason','local closed without unblocking'));
 if not app_private.match_pair_blocked(md5('safe-basic1user')::uuid,md5('safe-basic2user')::uuid) then raise exception 'dismiss removed exclusion';end if;
 delete from app_private.safety_reviewers where user_id=op;
 begin perform app_private.operations_safety_detail(jsonb_build_object('caseType','REPORT','caseId',report));raise exception 'revoked reviewer';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 -- No-show candidate is not a confirmed safety case; attendance correction removes case authority.
 s:=pg_temp.person_fixture('safe-past');select id,table_id into a,b from app_private.table_assignments where application_id=md5('safe-past1app')::uuid;
 select id into room from app_private.chat_rooms where table_id=b;
 perform pg_temp.safety('safe-past',1,2,'REPORT');
 if (select count(*) from app_private.table_assignments where table_id=b and active)<>4 or (select count(*) from app_private.actual_meetings where table_id=b)<>6 then raise exception 'past attendance destroyed';end if;
 begin perform app_private.chat_get(jsonb_build_object('roomId',room,'before',null));raise exception 'past safety chat not revoked';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 insert into app_private.attendance_records(assignment_id,closed_at,review_status) values(a,clock_timestamp(),'PENDING');
 insert into app_private.safety_reviewers values(op);perform set_config('app.actor_id',op::text,true);
 begin perform app_private.operations_safety_detail(jsonb_build_object('caseType','ATTENDANCE','caseId',a));raise exception 'candidate case';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 update app_private.attendance_records set review_status='NO_SHOW' where assignment_id=a;update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('safe-past1app')::uuid;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','ATTENDANCE','caseId',a,'requestKey',gen_random_uuid(),'revision',0,'action','RESTRICT','reason','local confirmed no show'));
 update app_private.intake_applications set attendance_status='ATTENDED' where id=md5('safe-past1app')::uuid;
 dto:=app_private.operations_safety_detail(jsonb_build_object('caseType','ATTENDANCE','caseId',a));if dto->>'status'<>'CORRECTED' then raise exception 'corrected case history missing';end if;
 begin perform app_private.operations_safety_review(jsonb_build_object('caseType','ATTENDANCE','caseId',a,'requestKey',gen_random_uuid(),'revision',1,'action','RESTRICT','reason','stale no show evidence'));raise exception 'stale no show sanction';exception when others then if sqlerrm<>'SAFETY_CONFLICT' then raise;end if;end;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','ATTENDANCE','caseId',a,'requestKey',gen_random_uuid(),'revision',1,'action','RESTORE','reason','corrected attendance restored'));
 n:=pg_temp.next_people('safe-next','safe-past',8);perform app_private.matching_tick();
 if (select count(*) from app_private.table_assignments x join app_private.dining_tables t on t.id=x.table_id where x.active and t.slot_id=n)<>8 then raise exception 'next round not allocated';end if;
 if exists(select 1 from app_private.table_assignments x join app_private.table_assignments y on x.table_id=y.table_id join app_private.dining_tables t on t.id=x.table_id where x.active and y.active and t.slot_id=n and x.user_id=md5('safe-past1user')::uuid and y.user_id=md5('safe-past2user')::uuid) then raise exception 'reported next pair';end if;
 if has_table_privilege('app_member_api','app_private.safety_reports','SELECT') or has_table_privilege('authenticated','app_private.safety_reviewers','INSERT') or has_function_privilege('app_member_api','app_private.safety_repair(uuid)','EXECUTE') then raise exception 'raw privilege leak';end if;
end $$;
do $$ declare s uuid;caseid uuid;op uuid:=md5('safety-hold-op')::uuid;k uuid:=gen_random_uuid();i int;dto jsonb;
begin
 s:=pg_temp.match_fixture('safe-restore',4);perform app_private.matching_tick();perform app_private.chat_tick();
 perform pg_temp.safety('safe-restore',1,2,'REPORT');select id into caseid from app_private.safety_reports where reporter_id=md5('safe-restore1user')::uuid;
 insert into auth.users(id) values(op);insert into app_private.member_accounts(user_id,role) values(op,'operator');insert into app_private.safety_reviewers values(op);
 perform set_config('app.actor_id',op::text,true);
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',caseid,'requestKey',gen_random_uuid(),'revision',0,'action','RESTRICT','reason','local hold before restore'));
 perform set_config('app.actor_id',md5('safe-restore2user')::uuid::text,true);
 begin perform app_private.intake_submit(jsonb_build_object('requestKey',gen_random_uuid()));raise exception 'restricted submit accepted';exception when others then if sqlerrm<>'PARTICIPATION_RESTRICTED' then raise;end if;end;
 perform set_config('app.actor_id',op::text,true);
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',caseid,'requestKey',k,'revision',1,'action','RESTORE','reason','local future restore'));
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',caseid,'requestKey',k,'revision',1,'action','RESTORE','reason','local future restore'));
 if (select matching_status from app_private.intake_applications where id=md5('safe-restore2app')::uuid)<>'REALLOCATING' or (select payment_status from app_private.intake_applications where id=md5('safe-restore2app')::uuid)<>'PAID' then raise exception 'future hold not requeued';end if;
 if (select count(*) from app_private.match_jobs where job_key like 'safety-restore:'||k||':%')<>1 then raise exception 'restore job duplicate';end if;
 if exists(select 1 from app_private.dining_tables where slot_id=s and status='CONFIRMED') then raise exception 'restore resurrected table';end if;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',caseid,'requestKey',gen_random_uuid(),'revision',2,'action','RESTRICT','reason','local hold before storage'));
 perform set_config('app.actor_id',md5('safe-restore2user')::uuid::text,true);
 perform app_private.match_resolve(jsonb_build_object('applicationId',md5('safe-restore2app')::uuid,'requestKey',gen_random_uuid(),'action','store'));
 if not (select credit_stored from app_private.intake_applications where id=md5('safe-restore2app')::uuid) then raise exception 'restricted storage blocked';end if;
 perform set_config('app.actor_id',op::text,true);
 perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',caseid,'requestKey',gen_random_uuid(),'revision',3,'action','RESTORE','reason','local storage stays stored'));
 if (select application_status from app_private.intake_applications where id=md5('safe-restore2app')::uuid)<>'CANCELED' then raise exception 'restore un-stored credit';end if;
 update app_private.member_accounts set role='operator' where user_id=md5('safe-restore2user')::uuid;
 begin perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId',caseid,'requestKey',gen_random_uuid(),'revision',4,'action','BAN','reason','operator account not sanctionable'));raise exception 'operator sanctioned';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 s:=pg_temp.person_fixture('safe-limit');k:=gen_random_uuid();perform pg_temp.safety('safe-limit',1,2,'REPORT',k);
 for i in 1..19 loop perform pg_temp.safety('safe-limit',1,2,'REPORT');end loop;
 begin perform pg_temp.safety('safe-limit',1,2,'REPORT');raise exception 'rate limit missing';exception when others then if sqlerrm<>'SAFETY_RATE_LIMIT' then raise;end if;end;
 perform pg_temp.safety('safe-limit',1,2,'REPORT',k);
 if (select count(*) from app_private.safety_reports where reporter_id=md5('safe-limit1user')::uuid)<>20 then raise exception 'rate replay count';end if;
 if has_table_privilege('app_member_api','app_private.safety_accounts','UPDATE') then raise exception 'state privilege leaked';end if;
end $$;
do $$ declare slot uuid;app uuid:=md5('safe-cancel1app')::uuid;op uuid:=md5('safety-cancel-op')::uuid;dto jsonb;
begin
 slot:=pg_temp.match_fixture('safe-cancel',4);perform app_private.matching_tick();
 update app_private.intake_event_slots set refund_cutoff_at=clock_timestamp()-interval '1 minute' where id=slot;
 perform set_config('app.actor_id',md5('safe-cancel1user')::uuid::text,true);
 perform app_private.match_resolve(jsonb_build_object('applicationId',app,'requestKey',gen_random_uuid(),'action','cancel'));
 if (select attendance_status from app_private.intake_applications where id=app)<>'CANCELED_LATE' then raise exception 'real late cancellation missing';end if;
 insert into auth.users(id) values(op);insert into app_private.member_accounts(user_id,role) values(op,'operator');insert into app_private.safety_reviewers values(op);
 perform set_config('app.actor_id',op::text,true);dto:=app_private.operations_safety_get();
 if not exists(select 1 from jsonb_array_elements(dto->'cases') c where c->>'caseType'='CANCELLATION' and c->>'caseId'=app::text) then raise exception 'late cancellation case missing';end if;
 dto:=app_private.operations_safety_detail(jsonb_build_object('caseType','CANCELLATION','caseId',app));
 if dto->>'status'<>'REVIEW' or dto->'details'<>'null'::jsonb then raise exception 'cancellation detail';end if;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','CANCELLATION','caseId',app,'requestKey',gen_random_uuid(),'revision',0,'action','RESTRICT','reason','local late cancellation review'));
 update app_private.intake_applications set attendance_status='CANCELED_EARLY' where id=app;
 dto:=app_private.operations_safety_detail(jsonb_build_object('caseType','CANCELLATION','caseId',app));
 if dto->>'status'<>'CORRECTED' then raise exception 'cancel correction history missing';end if;
 begin perform app_private.operations_safety_review(jsonb_build_object('caseType','CANCELLATION','caseId',app,'requestKey',gen_random_uuid(),'revision',1,'action','BAN','reason','stale cancellation evidence'));raise exception 'corrected cancellation banned';exception when others then if sqlerrm<>'SAFETY_CONFLICT' then raise;end if;end;
 perform app_private.operations_safety_review(jsonb_build_object('caseType','CANCELLATION','caseId',app,'requestKey',gen_random_uuid(),'revision',1,'action','RESTORE','reason','local cancellation correction restore'));
 if not app_private.safety_allowed(md5('safe-cancel1user')::uuid) then raise exception 'cancel correction not restored';end if;
end $$;
rollback;
