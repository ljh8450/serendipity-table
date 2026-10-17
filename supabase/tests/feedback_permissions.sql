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



create function pg_temp.feedback_payload(target uuid,req uuid default gen_random_uuid()) returns jsonb language sql as $$select jsonb_build_object('assignmentId',target,'requestKey',req,'ratings',jsonb_build_object('atmosphere',4,'conversation',5,'venue',3,'revisit',true,'recommend',false))$$;
create function pg_temp.fail_feedback() returns trigger language plpgsql as $$begin if new.kind='FEEDBACK_REQUEST' and new.user_id=md5('fdb-basic3user')::uuid then raise exception 'LOCAL INJECTED';end if;return new;end $$;
do $$ declare slot uuid;target uuid;second uuid;third uuid;k uuid:=gen_random_uuid();dto jsonb;j uuid;op uuid:=md5('fdb-operator')::uuid;i int;
begin
 slot:=pg_temp.match_fixture('fdb-basic',4);perform app_private.matching_tick();
 select id into target from app_private.table_assignments where application_id=md5('fdb-basic1app')::uuid;
 select id into second from app_private.table_assignments where application_id=md5('fdb-basic2app')::uuid;
 select id into third from app_private.table_assignments where application_id=md5('fdb-basic3app')::uuid;
 perform set_config('app.actor_id',md5('fdb-basic1user')::uuid::text,true);
 if jsonb_array_length(app_private.feedback_get()->'events')<>0 then raise exception 'before end exposed';end if;
 begin perform app_private.feedback_submit(pg_temp.feedback_payload(target,k));raise exception 'early accepted';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.operations_feedback_get();raise exception 'operator access';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=slot;
 update app_private.intake_applications set attendance_status='ATTENDED' where id in(md5('fdb-basic1app')::uuid,md5('fdb-basic2app')::uuid);
 insert into app_private.push_subscriptions(user_id,endpoint,p256dh,auth) values(md5('fdb-basic1user')::uuid,'https://fcm.googleapis.com/fcm/send/LOCAL_FEEDBACK_ONLY','B'||repeat('A',86),repeat('A',22));
 perform app_private.feedback_tick();perform app_private.feedback_tick();
 if (select count(*) from app_private.feedback_jobs where kind='REQUEST' and status='DONE')<>2 then raise exception 'request eligibility/uniqueness';end if;
 if (select count(*) from app_private.member_notifications where kind='FEEDBACK_REQUEST')<>2 then raise exception 'request duplicate';end if;
 if not exists(select 1 from app_private.push_jobs p join app_private.member_notifications n on n.id=p.notification_id where n.kind='FEEDBACK_REQUEST') then raise exception 'push queue missing';end if;
 if exists(select 1 from app_private.feedback_jobs r join app_private.feedback_jobs q on q.assignment_id=r.assignment_id and q.kind='REQUEST' where r.kind='REMINDER' and r.due_at<>q.finished_at+interval '24 hours') then raise exception 'reminder timing';end if;
 update app_private.feedback_jobs set due_at=clock_timestamp() where kind='REMINDER';
 perform app_private.feedback_tick();perform app_private.feedback_tick();
 if (select count(*) from app_private.member_notifications where kind='FEEDBACK_REMINDER')<>2 then raise exception 'one reminder';end if;
 begin perform app_private.feedback_submit(pg_temp.feedback_payload(second));raise exception 'foreign accepted';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.feedback_submit(pg_temp.feedback_payload(target)||'{"now":"future"}');raise exception 'clock accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform app_private.feedback_submit(jsonb_set(pg_temp.feedback_payload(target),'{ratings,venue}','6'));raise exception 'score accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform app_private.feedback_submit(jsonb_set(pg_temp.feedback_payload(target),'{ratings,revisit}','"true"'));raise exception 'boolean string accepted';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 dto:=app_private.feedback_submit(pg_temp.feedback_payload(target,k));
 perform app_private.feedback_submit(pg_temp.feedback_payload(target,k));
 begin perform app_private.feedback_submit(jsonb_set(pg_temp.feedback_payload(target,k),'{ratings,venue}','4'));raise exception 'changed replay';exception when others then if sqlerrm<>'FEEDBACK_CONFLICT' then raise;end if;end;
 if (select count(*) from app_private.event_feedback where assignment_id=target)<>1 then raise exception 'duplicate feedback';end if;
 if dto::text ~ 'user_id|requestKey|request_key|member_id' then raise exception 'feedback identity leak';end if;
 if exists(select 1 from jsonb_array_elements(app_private.notifications_get()->'notifications') n where n->>'kind' in('FEEDBACK_REQUEST','FEEDBACK_REMINDER')) then raise exception 'answered notice remains';end if;
 if exists(select 1 from app_private.push_jobs p join app_private.member_notifications n on n.id=p.notification_id where n.user_id=md5('fdb-basic1user')::uuid and n.kind like 'FEEDBACK_%' and p.status<>'CANCELED') then raise exception 'answered push remains';end if;
 update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('fdb-basic1app')::uuid;
 begin perform app_private.feedback_submit(pg_temp.feedback_payload(target,k));raise exception 'revoked replay';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 if jsonb_array_length(app_private.feedback_get()->'events')<>0 then raise exception 'revoked history';end if;
 update app_private.intake_applications set attendance_status='ATTENDED' where id=md5('fdb-basic3app')::uuid;
 execute 'create trigger local_fail_feedback before insert on app_private.member_notifications for each row execute function pg_temp.fail_feedback()';
 for i in 1..3 loop update app_private.feedback_jobs set due_at=clock_timestamp() where assignment_id=third;perform app_private.feedback_tick();end loop;
 select id into j from app_private.feedback_jobs where assignment_id=third and kind='REQUEST' and status='EXCEPTION';
 if j is null then raise exception 'retry budget missing';end if;
 execute 'drop trigger local_fail_feedback on app_private.member_notifications';
 insert into auth.users(id) values(op);insert into app_private.member_accounts(user_id,role) values(op,'operator');perform set_config('app.actor_id',op::text,true);
 dto:=app_private.operations_feedback_retry(jsonb_build_object('jobId',j));perform app_private.feedback_tick();
 if (select status from app_private.feedback_jobs where id=j)<>'DONE' then raise exception 'operator recovery failed';end if;
 if dto::text ~ 'ratings|revisit|recommend|user_id|assignmentId' then raise exception 'operator evaluation leak';end if;
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours 7 days',opens_at=clock_timestamp()-interval '9 days',closes_at=clock_timestamp()-interval '8 days',matches_at=clock_timestamp()-interval '8 days' where id=slot;
 perform set_config('app.actor_id',md5('fdb-basic2user')::uuid::text,true);
 begin perform app_private.feedback_submit(pg_temp.feedback_payload(second));raise exception 'deadline accepted';exception when others then if sqlerrm<>'FEEDBACK_CLOSED' then raise;end if;end;
 if exists(select 1 from jsonb_array_elements(app_private.notifications_get()->'notifications') n where n->>'kind' like 'FEEDBACK_%') then raise exception 'expired notice';end if;
 if has_table_privilege('app_member_api','app_private.event_feedback','INSERT') or has_function_privilege('authenticated','app_private.feedback_get()','EXECUTE') or has_function_privilege('app_member_api','app_private.feedback_tick()','EXECUTE') then raise exception 'grants leaked';end if;
 if (select count(*) from cron.job where jobname='serendipity-feedback-tick' and active)<>1 then raise exception 'cron missing';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('fdb-basic2user')::uuid::text,true);
select app_private.feedback_get();
reset role;
rollback;
