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


do $$ declare slot uuid;target uuid;other_target uuid;req uuid:=gen_random_uuid();dto jsonb;operator uuid:=md5('att-operator')::uuid;review_key uuid:=gen_random_uuid();
begin
 slot:=pg_temp.match_fixture('att-basic',4);perform app_private.matching_tick();
 select id into target from app_private.table_assignments where application_id=md5('att-basic1app')::uuid;
 select id into other_target from app_private.table_assignments where application_id=md5('att-basic2app')::uuid;
 perform set_config('app.actor_id',md5('att-basic1user')::uuid::text,true);
 begin perform app_private.attendance_check_in(jsonb_build_object('assignmentId',target,'requestKey',req));raise exception 'early checkin accepted';exception when others then if sqlerrm<>'CHECK_IN_CLOSED' then raise;end if;end;
 begin perform app_private.attendance_check_in(jsonb_build_object('assignmentId',other_target,'requestKey',req));raise exception 'foreign checkin accepted';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.attendance_check_in(jsonb_build_object('assignmentId',target,'requestKey',req,'now','future'));raise exception 'clock injection';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 begin perform app_private.operations_attendance_get();raise exception 'participant monitor';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 update app_private.intake_event_slots set starts_at=clock_timestamp()+interval '30 minutes' where id=slot;
 dto:=app_private.attendance_get();if not (dto->'attendances'->0->>'canCheckIn')::boolean then raise exception 'open window';end if;
 perform app_private.attendance_check_in(jsonb_build_object('assignmentId',target,'requestKey',req));
 perform app_private.attendance_check_in(jsonb_build_object('assignmentId',target,'requestKey',req));
 perform app_private.attendance_check_in(jsonb_build_object('assignmentId',target,'requestKey',gen_random_uuid()));
 if (select count(*) from app_private.attendance_actions where assignment_id=target)<>1 then raise exception 'duplicate checkin';end if;
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=slot;
 perform set_config('app.actor_id',md5('att-basic2user')::uuid::text,true);
 begin perform app_private.attendance_check_in(jsonb_build_object('assignmentId',other_target,'requestKey',gen_random_uuid()));raise exception 'late checkin accepted';exception when others then if sqlerrm<>'CHECK_IN_CLOSED' then raise;end if;end;
 perform app_private.attendance_tick();perform app_private.attendance_tick();
 if (select count(*) from app_private.attendance_records where review_status='PENDING' and assignment_id in(select id from app_private.table_assignments where table_id=(select table_id from app_private.table_assignments where id=target)))<>3 then raise exception 'candidate count';end if;
 if (select attendance_status from app_private.intake_applications where id=md5('att-basic2app')::uuid)<>'SCHEDULED' then raise exception 'automatic noshow';end if;
 if (select closed_at from app_private.attendance_records where assignment_id=target) is null then raise exception 'checked in not closed';end if;
 insert into auth.users(id) values(operator);insert into app_private.member_accounts(user_id,role) values(operator,'operator');
 perform set_config('app.actor_id',operator::text,true);
 dto:=app_private.operations_attendance_review(jsonb_build_object('assignmentId',other_target,'requestKey',review_key,'outcome','NO_SHOW','reason','LOCAL verified absent'));
 perform app_private.operations_attendance_review(jsonb_build_object('assignmentId',other_target,'requestKey',review_key,'outcome','NO_SHOW','reason','LOCAL verified absent'));
 begin perform app_private.operations_attendance_review(jsonb_build_object('assignmentId',other_target,'requestKey',review_key,'outcome','ATTENDED','reason','LOCAL correction'));raise exception 'changed replay';exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 if dto::text ~ 'LOCAL verified|actor_id|user_id|contact|reason' then raise exception 'private review leak';end if;
 perform app_private.operations_attendance_review(jsonb_build_object('assignmentId',other_target,'requestKey',gen_random_uuid(),'outcome','ATTENDED','reason','LOCAL correction'));
 if (select attendance_status from app_private.intake_applications where id=md5('att-basic2app')::uuid)<>'ATTENDED' or (select count(*) from app_private.attendance_actions where assignment_id=other_target)<>2 then raise exception 'correction audit';end if;
 if exists(select 1 from app_private.member_accounts where user_id=md5('att-basic2user')::uuid and restricted) then raise exception 'automatic restriction';end if;
 update app_private.table_assignments set active=false where id=target;
 perform set_config('app.actor_id',md5('att-basic1user')::uuid::text,true);
 begin perform app_private.attendance_check_in(jsonb_build_object('assignmentId',target,'requestKey',req));raise exception 'revoked replay';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 if jsonb_array_length(app_private.attendance_get()->'attendances')<>0 then raise exception 'revoked DTO';end if;
 if has_table_privilege('app_member_api','app_private.attendance_records','INSERT') or has_function_privilege('authenticated','app_private.attendance_check_in(jsonb)','EXECUTE') or has_function_privilege('app_member_api','app_private.attendance_tick()','EXECUTE') then raise exception 'grants leak';end if;
 if (select count(*) from cron.job where jobname='serendipity-attendance-tick' and active)<>1 then raise exception 'cron missing';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('att-basic2user')::uuid::text,true);
select app_private.attendance_get();
reset role;
rollback;
