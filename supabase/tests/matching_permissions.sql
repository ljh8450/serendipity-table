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
do $$ declare count_n int; slot uuid; allocated int; before_count int; begin
 foreach count_n in array array[3,4,5,6,7,8,10,12] loop
  slot:=pg_temp.match_fixture('n'||count_n,count_n);
  perform app_private.matching_tick();
  select count(*) into allocated from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=slot and a.active;
  if allocated<>(case when count_n=3 then 0 when count_n=7 then 6 else count_n end) then raise exception 'n=% expected allocation, actual=%; job errors=%',count_n,allocated,(select jsonb_agg(last_error) from app_private.match_jobs where slot_id=slot); end if;
  if exists(select 1 from app_private.dining_tables t where t.slot_id=slot and (select count(*) from app_private.table_assignments a where a.table_id=t.id and a.active) not between 4 and 6) then raise exception 'illegal table size'; end if;
  if count_n=8 and (select count(*) from app_private.dining_tables where slot_id=slot)<>2 then raise exception '8 was not 4+4'; end if;
  select count(*) into before_count from app_private.match_outbox;
  perform app_private.matching_tick();
  if (select count(*) from app_private.match_outbox)<>before_count then raise exception 'duplicate outbox'; end if;
 end loop;
end $$;
do $$ declare slot uuid; other uuid; label text; reason text; gap int; stage int; allocated int; ta record; j app_private.match_jobs%rowtype; old_token uuid;
begin
 foreach gap in array array[8,9] loop
  label:='age-'||gap;slot:=pg_temp.match_fixture(label,4,gap);perform app_private.matching_tick();
  select count(*) into allocated from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=slot and a.active;
  if allocated<>(case when gap=8 then 4 else 0 end) then raise exception 'age boundary % wrong',gap; end if;
 end loop;
 slot:=pg_temp.match_fixture('unpaid',4);update app_private.intake_applications set payment_status='PENDING' where id=md5('unpaid4app')::uuid;perform app_private.matching_tick();
 if exists(select 1 from app_private.dining_tables where slot_id=slot) then raise exception 'unpaid member included'; end if;
 foreach reason in array array['block','report','dislike'] loop
  label:='exclude-'||reason;slot:=pg_temp.match_fixture(label,4);
  insert into app_private.match_relations(user_low,user_high,reason) values(least(md5(label||'1user')::uuid,md5(label||'2user')::uuid),greatest(md5(label||'1user')::uuid,md5(label||'2user')::uuid),reason);
  perform app_private.matching_tick();if exists(select 1 from app_private.dining_tables where slot_id=slot) then raise exception 'excluded relation % included',reason;end if;
 end loop;
 for stage in 1..2 loop
  label:='score-'||stage;slot:=pg_temp.match_fixture(label,4);
  update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"gender":"male"}' where input->'slotIds' ? slot::text;
  update app_private.matching_policy set minimum_score=case when stage=1 then 75 else 75.01 end where active;
  perform app_private.matching_tick();
  if (select count(*) from app_private.dining_tables where slot_id=slot)<>(case when stage=1 then 1 else 0 end) then raise exception 'score boundary or single-gender wrong';end if;
 end loop;
 update app_private.matching_policy set minimum_score=35 where active;
 slot:=pg_temp.match_fixture('newpeople',8);
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"gender":"male"}' where input->'slotIds' ? slot::text;
 insert into app_private.encounters(user_low,user_high,source_key,occurred_at) values(least(md5('newpeople1user')::uuid,md5('newpeople2user')::uuid),greatest(md5('newpeople1user')::uuid,md5('newpeople2user')::uuid),'fixture-attended',now()-interval '1 day');
 perform app_private.matching_tick();
 if exists(select 1 from app_private.table_assignments a join app_private.table_assignments b on a.table_id=b.table_id where a.active and b.active and a.user_id=md5('newpeople1user')::uuid and b.user_id=md5('newpeople2user')::uuid) then raise exception 'previous encounter ignored in equal-score choice';end if;
 select a.table_id,min(a.user_id::text)::uuid lo,max(a.user_id::text)::uuid hi into ta from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=slot and a.active group by a.table_id limit 1;
 insert into app_private.match_relations(user_low,user_high,reason) values(ta.lo,ta.hi,'report');
 if exists(select 1 from app_private.table_assignments where table_id=ta.table_id and active) then raise exception 'post-confirm report did not fence table';end if;
 -- Finish repair job before later cases so its priority cannot consume their tick.
 perform app_private.matching_tick();
 for stage in 1..4 loop
  label:='relocate-'||stage;slot:=pg_temp.match_fixture(label||'a',3);other:=pg_temp.match_fixture(label||'b',1);
  -- Fixed Seoul noon keeps same-date cases valid even when tests run near midnight.
  update app_private.intake_event_slots set starts_at=(date_trunc('day',now() at time zone 'Asia/Seoul')+interval '7 days 12 hours') at time zone 'Asia/Seoul' where id=slot;
  update app_private.intake_event_slots set starts_at=((date_trunc('day',now() at time zone 'Asia/Seoul')+interval '7 days 12 hours') at time zone 'Asia/Seoul')+case when stage<=2 then interval '1 hour' else interval '1 day' end,region_code=case when stage in(2,4) then 'jamsil' else 'hongdae' end where id=other;
  update app_private.intake_applications set input=jsonb_set(jsonb_set(input,'{slotIds}',jsonb_build_array(slot,other)),'{regions}','["hongdae","jamsil"]') where input->'slotIds' ? slot::text;
  update app_private.intake_applications set input=jsonb_set(input,'{regions}','["hongdae","jamsil"]') where input->'slotIds' ? other::text;
  perform app_private.matching_tick();
  if (select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=other and a.active)<>4 then raise exception 'reallocation % failed',stage;end if;
  if (select count(*) from app_private.allocation_attempts h where h.slot_id=other and h.step=stage and h.reason='REALLOCATED')<>3 then raise exception 'reallocation step % lost',stage;end if;
  perform app_private.matching_tick();
 end loop;
 slot:=pg_temp.match_fixture('defer-a',3);other:=pg_temp.match_fixture('defer-b',1);
 update app_private.intake_event_slots set starts_at=now()+interval '8 days',matches_at=now()+interval '2 minutes' where id=other;
 update app_private.intake_applications set input=jsonb_set(input,'{slotIds}',jsonb_build_array(slot,other)) where input->'slotIds' ? slot::text;
 perform app_private.matching_tick();
 if (select count(*) from app_private.intake_applications where input->'slotIds' ? slot::text and matching_status='REALLOCATING')<>3 then raise exception 'future selection prematurely failed';end if;
 update app_private.intake_event_slots set matches_at=now()-interval '1 minute' where id=other;
 perform app_private.matching_tick();
 if (select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=other and a.active)<>4 then raise exception 'future slot retry failed';end if;
 slot:=pg_temp.match_fixture('lease',4);perform app_private.match_enqueue();j:=app_private.match_claim();old_token:=j.token;
 update app_private.match_jobs set lease_until=clock_timestamp()-interval '1 second' where id=j.id;
 j:=app_private.match_claim();if j.token=old_token then raise exception 'lease fencing token unchanged';end if;
 begin perform app_private.match_process(j.id,old_token);raise exception 'stale worker committed' using errcode='22023';exception when raise_exception then if sqlerrm<>'STALE_CLAIM' then raise;end if;end;
 perform app_private.match_process(j.id,j.token);
 slot:=pg_temp.match_fixture('capacity',8);update app_private.intake_event_slots set capacity=4 where id=slot;perform app_private.matching_tick();
 if (select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=slot and a.active)<>4 then raise exception 'slot capacity exceeded';end if;
 slot:=pg_temp.match_fixture('large-progress',20);perform app_private.matching_tick();perform app_private.matching_tick();
 -- first batch reserves a legal remainder; second tick may be delayed by one second
 update app_private.match_jobs set due_at=clock_timestamp() where slot_id=slot and status='QUEUED';perform app_private.matching_tick();
 if (select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=slot and a.active)<>20 then raise exception 'large batch progress stranded users';end if;
 slot:=pg_temp.match_fixture('exhausted',18);update app_private.matching_policy set minimum_score=100 where active;
 for stage in 1..3 loop
  update app_private.match_jobs set due_at=clock_timestamp() where slot_id=slot;perform app_private.matching_tick();
 end loop;
 if not exists(select 1 from app_private.match_jobs where slot_id=slot and status='EXCEPTION' and attempts=3) then raise exception 'retries not exhausted durably';end if;
 if not exists(select 1 from app_private.match_exceptions x join app_private.match_jobs jobs on jobs.id=x.job_id where jobs.slot_id=slot and x.code='SEARCH_WINDOW_EXHAUSTED') then raise exception 'missing final exception';end if;
 update app_private.matching_policy set minimum_score=35 where active;
end $$;
do $$ declare slot uuid; j app_private.match_jobs%rowtype; i int; begin
 slot:=pg_temp.match_fixture('lease-exhaust',4);
 for i in 1..3 loop j:=app_private.match_claim();update app_private.match_jobs set lease_until=clock_timestamp()-interval '1 second' where id=j.id;end loop;
 j:=app_private.match_claim();
 if j.id is not null or not exists(select 1 from app_private.match_jobs where slot_id=slot and status='EXCEPTION' and last_error='LEASE_EXPIRED' and attempts=3) then raise exception 'lease exhaustion not recorded';end if;
 slot:=pg_temp.match_fixture('invalid-profile',4);update app_private.intake_applications set onboarding_snapshot='{}' where id=md5('invalid-profile1app')::uuid;
 for i in 1..3 loop update app_private.match_jobs set due_at=clock_timestamp() where slot_id=slot;perform app_private.matching_tick();end loop;
 if not exists(select 1 from app_private.match_jobs where slot_id=slot and status='EXCEPTION' and last_error='PROFILE_REQUIRED') then raise exception 'invalid profile silently completed';end if;
 slot:=pg_temp.match_fixture('healthy-after-bad',4);for i in 1..4 loop update app_private.match_jobs set due_at=clock_timestamp() where slot_id=slot and status='QUEUED';perform app_private.matching_tick();end loop;
 if not exists(select 1 from app_private.dining_tables where slot_id=slot) then raise exception 'bad input blocked unrelated healthy job';end if;
 slot:=pg_temp.match_fixture('missed-window',4);update app_private.intake_event_slots set starts_at=now()-interval '30 seconds' where id=slot;
 for i in 1..3 loop update app_private.match_jobs set due_at=clock_timestamp() where slot_id=slot;perform app_private.matching_tick();end loop;
 if not exists(select 1 from app_private.match_jobs where slot_id=slot and status='EXCEPTION' and last_error='MISSED_MATCH_WINDOW') then raise exception 'missed window silently completed';end if;
end $$;
do $$ declare slot uuid; other uuid; assigned_app uuid; leftover_app uuid; usr uuid; table_key uuid; occupied tstzrange; member_id uuid;
begin
 slot:=pg_temp.match_fixture('overlap-a',4);other:=pg_temp.match_fixture('overlap-b',4);usr:=md5('overlap-a1user')::uuid;
 update app_private.intake_applications set user_id=usr where id=md5('overlap-b1app')::uuid;
 update app_private.payment_attempts set user_id=usr where application_id=md5('overlap-b1app')::uuid;
 perform app_private.matching_tick();perform app_private.matching_tick();
 if (select count(*) from app_private.table_assignments where user_id=usr and active)>1 then raise exception 'overlapping same-user applications double assigned';end if;
 select application_id,table_id,occupied_at into assigned_app,table_key,occupied from app_private.table_assignments where user_id=usr and active;
 select id into leftover_app from app_private.intake_applications where user_id=usr and id<>assigned_app;
 if assigned_app is null then raise exception 'overlap fixture failed to assign one valid application';end if;
 begin insert into app_private.table_assignments(table_id,application_id,user_id,occupied_at) values(table_key,leftover_app,usr,occupied);raise exception 'DB overlap exclusion missing' using errcode='22023';exception when exclusion_violation then null;end;
 slot:=pg_temp.match_fixture('membership-failure',3);
 for usr in select user_id from app_private.intake_applications where input->'slotIds' ? slot::text loop
  insert into app_private.memberships(user_id,starts_at,ends_at,product_code) values(usr,now()-interval '1 day',now()+interval '1 month','membership_1') returning id into member_id;
  update app_private.intake_applications set membership_id=member_id,product_snapshot='{"code":"membership_use","kind":"membership_use","amountKrw":0}' where user_id=usr;
 end loop;
 perform app_private.matching_tick();perform app_private.matching_tick();
 if (select count(*) from app_private.membership_extensions x join app_private.intake_applications a on a.id=x.application_id where a.input->'slotIds' ? slot::text)<>3 then raise exception 'automatic membership failure extension missing/doubled';end if;
 slot:=pg_temp.match_fixture('expired-membership',4);usr:=md5('expired-membership1user')::uuid;
 insert into app_private.memberships(user_id,starts_at,ends_at,product_code) values(usr,now()-interval '1 month',now()-interval '1 second','membership_1') returning id into member_id;
 update app_private.intake_applications set membership_id=member_id where user_id=usr;perform app_private.matching_tick();
 if exists(select 1 from app_private.dining_tables where slot_id=slot) then raise exception 'expired entitlement confirmed';end if;
end $$;
do $$ declare slot uuid;i int;begin
 slot:=pg_temp.match_fixture('window-rotation',20);
 for i in 1..16 loop update app_private.intake_applications set onboarding_snapshot=jsonb_set(onboarding_snapshot,'{birthYear}',to_jsonb(1900+i*5)) where id=md5('window-rotation'||i||'app')::uuid;end loop;
 update app_private.intake_applications set onboarding_snapshot=jsonb_set(onboarding_snapshot,'{birthYear}','2000') where input->'slotIds' ? slot::text and id not in(select md5('window-rotation'||series.n||'app')::uuid from generate_series(1,16) series(n));
 for i in 1..3 loop update app_private.match_jobs set due_at=clock_timestamp() where slot_id=slot and status='QUEUED';perform app_private.matching_tick();end loop;
 if (select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=slot and a.active)<>4 then raise exception 'retry failed to rotate beyond incompatible prefix';end if;
end $$;
-- The browser command role can read only its own sanitized outcome, never execute workers.
select set_config('app.actor_id',md5('n41user')::uuid::text,true);
set local role app_member_api;
do $$ declare dto jsonb;begin
 dto:=app_private.matching_get();
 if jsonb_array_length(dto->'applications')<>1 or dto->'applications'->0->>'status'<>'CONFIRMED' then raise exception 'own result missing';end if;
 if dto::text like '%birthYear%' or dto::text like '%score%' or dto::text like '%user_low%' then raise exception 'private matching data leaked';end if;
 begin perform app_private.matching_tick();raise exception 'member executed worker';exception when insufficient_privilege then null;end;
 begin perform 1 from app_private.match_runs;raise exception 'member read private run';exception when insufficient_privilege then null;end;
 begin perform app_private.operations_matching_get();raise exception 'participant read monitor' using errcode='22023';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
end $$;
reset role;
rollback;





