-- Bounded, deterministic candidate generation and beam set packing; no network calls.
create function app_private.match_process(job_id uuid,claim_token uuid) returns void
language plpgsql security definer set search_path='' as $$
declare job app_private.match_jobs%rowtype; policy app_private.matching_policy%rowtype; run_id uuid; total int; pool_limit int;
 depth int; nodes int:=0; candidate_count int; best record; candidate record; item record; chosen uuid; assigned int:=0; start_time timestamptz:=clock_timestamp();
 n int; future_slot boolean; remaining int; explanation text; live_score numeric;
begin
 -- A single global finalization fence also serializes relationship changes.
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 select * into job from app_private.match_jobs where id=job_id for update;
 if job.id is null or job.status<>'RUNNING' or job.token is distinct from claim_token or job.lease_until<=clock_timestamp() then raise exception 'STALE_CLAIM'; end if;
 select * into policy from app_private.matching_policy where active for share;
 if policy.version is null then raise exception 'POLICY_MISSING'; end if;
 if not exists(select 1 from app_private.intake_event_slots where id=job.slot_id and published and matches_at<=clock_timestamp() and starts_at>clock_timestamp()) then
  update app_private.match_jobs set status='DONE',finished_at=clock_timestamp(),lease_until=null where id=job.id;
  update app_private.match_job_attempts set outcome='SKIPPED',finished_at=clock_timestamp() where token=claim_token;
  return;
 end if;
 insert into app_private.match_runs(job_id,token,policy_version,policy_snapshot) values(job.id,claim_token,policy.version,to_jsonb(policy)) returning id into run_id;
 drop table if exists pg_temp.match_pool,pg_temp.match_pairs,pg_temp.match_candidates,pg_temp.match_states,pg_temp.match_next;
 create temporary table match_pool(i int primary key,app_id uuid unique,user_id uuid unique,born int,profile jsonb,input jsonb,submitted timestamptz) on commit drop;
 -- All due selected slots are considered together; future slots are never confirmed early.
 select count(distinct a.user_id) into total from app_private.intake_applications a
 where a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a)
 and coalesce(a.onboarding_snapshot->>'birthYear','') ~ '^[0-9]{4}$'
 and exists(select 1 from app_private.intake_event_slots e where e.published and e.matches_at<=clock_timestamp() and e.starts_at>clock_timestamp() and a.input->'slotIds' ? e.id::text and a.input->'regions' ? e.region_code);
 pool_limit:=policy.batch_size;
 if total>pool_limit and total-pool_limit between 1 and 3 then pool_limit:=total-4; end if;
 insert into pg_temp.match_pool
 select row_number() over(order by (a.onboarding_snapshot->>'birthYear')::int,a.submitted_at,a.id),a.id,a.user_id,(a.onboarding_snapshot->>'birthYear')::int,a.onboarding_snapshot,a.input,a.submitted_at
 from (select distinct on(a.user_id) a.* from app_private.intake_applications a
 where a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a)
 and coalesce(a.onboarding_snapshot->>'birthYear','') ~ '^[0-9]{4}$'
 and jsonb_typeof(a.onboarding_snapshot->'mbti')='array' and jsonb_typeof(a.onboarding_snapshot->'interests')='array'
 and jsonb_typeof(a.onboarding_snapshot->'traits')='array' and jsonb_typeof(a.onboarding_snapshot->'preferredTraits')='array'
 and exists(select 1 from app_private.intake_event_slots e where e.published and e.matches_at<=clock_timestamp() and e.starts_at>clock_timestamp() and a.input->'slotIds' ? e.id::text and a.input->'regions' ? e.region_code)
 order by a.user_id,a.submitted_at,a.id) a
 order by (a.onboarding_snapshot->>'birthYear')::int,a.submitted_at,a.id limit pool_limit;
 select count(*) into n from pg_temp.match_pool;
 -- Lock current account, application and entitlement facts before planning/finalization.
 perform 1 from app_private.member_accounts where user_id in(select user_id from pg_temp.match_pool) order by user_id for share;
 perform 1 from app_private.intake_applications where id in(select app_id from pg_temp.match_pool) order by id for update;
 perform 1 from app_private.memberships where id in(select membership_id from app_private.intake_applications where id in(select app_id from pg_temp.match_pool)) order by id for share;
 perform 1 from app_private.intake_event_slots where published and matches_at<=clock_timestamp() and starts_at>clock_timestamp() order by id for update;
 delete from pg_temp.match_pool p where not exists(select 1 from app_private.intake_applications a where a.id=p.app_id and a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a));
 update app_private.match_runs set input_snapshot=coalesce((select jsonb_agg(jsonb_build_object('applicationId',app_id,'profile',profile,'input',input) order by i) from pg_temp.match_pool),'[]') where id=run_id;
 create temporary table match_pairs on commit drop as
 select a.i lo,b.i hi,app_private.match_pair_score(a.profile,b.profile,policy.weights) score,
 exists(select 1 from app_private.match_relations r where r.user_low=least(a.user_id,b.user_id) and r.user_high=greatest(a.user_id,b.user_id)) blocked,
 exists(select 1 from app_private.encounters h where h.user_low=least(a.user_id,b.user_id) and h.user_high=greatest(a.user_id,b.user_id)) met
 from pg_temp.match_pool a join pg_temp.match_pool b on a.i<b.i;
 create unique index on match_pairs(lo,hi);
 create temporary table match_candidates(id bigint generated always as identity primary key,slot_id uuid,indices int[],mask bigint,size int,score numeric,step_cost int,met int) on commit drop;
 insert into pg_temp.match_candidates(slot_id,indices,mask,size,score,step_cost,met)
 with recursive combos as (
  select e.id slot_id,array[p.i] indices,(1::bigint << p.i) mask,p.i last_i,p.born youngest,p.born oldest,0::numeric score_sum,0::int met,app_private.match_step(p.input,e.id) step_cost
  from pg_temp.match_pool p join app_private.intake_event_slots e on p.input->'slotIds' ? e.id::text and p.input->'regions' ? e.region_code
  where e.published and e.matches_at<=clock_timestamp() and e.starts_at>clock_timestamp()
  and not exists(select 1 from app_private.table_assignments ta where ta.user_id=p.user_id and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+make_interval(hours=>policy.duration_hours),'[)'))
  union all
  select c.slot_id,c.indices||p.i,c.mask | (1::bigint<<p.i),p.i,greatest(c.youngest,p.born),least(c.oldest,p.born),c.score_sum+pair.score,c.met+pair.met,c.step_cost+app_private.match_step(p.input,c.slot_id)
  from combos c join pg_temp.match_pool p on p.i>c.last_i
  join app_private.intake_event_slots e on e.id=c.slot_id and p.input->'slotIds' ? e.id::text and p.input->'regions' ? e.region_code
  cross join lateral (select sum(mp.score) score,count(*) filter(where mp.met)::int met,bool_or(mp.blocked) blocked from pg_temp.match_pairs mp where mp.hi=p.i and mp.lo=any(c.indices)) pair
  where cardinality(c.indices)<6 and greatest(c.youngest,p.born)-least(c.oldest,p.born)<=8 and not pair.blocked
  and not exists(select 1 from app_private.table_assignments ta where ta.user_id=p.user_id and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+make_interval(hours=>policy.duration_hours),'[)'))
 )
 select slot_id,indices,mask,cardinality(indices),score_sum/(cardinality(indices)*(cardinality(indices)-1)/2),step_cost,met from combos
 where cardinality(indices) between 4 and 6 and score_sum/(cardinality(indices)*(cardinality(indices)-1)/2)>=policy.minimum_score
 order by slot_id,mask;
 get diagnostics candidate_count=row_count;
 create temporary table match_states(mask bigint primary key,chosen bigint[],placed int,score numeric,step_cost int,met int) on commit drop;
 create temporary table match_next(like match_states including all) on commit drop;
 insert into pg_temp.match_states values(0,'{}',0,0,0,0);
 best:=row(0::bigint,'{}'::bigint[],0::int,0::numeric,0::int,0::int);
 for depth in 1..greatest(1,n/4) loop
  truncate pg_temp.match_next;
  insert into pg_temp.match_next
  select mask,chosen,placed,score,step_cost,met from (
   select distinct on(s.mask|c.mask) s.mask|c.mask mask,s.chosen||c.id chosen,s.placed+c.size placed,s.score+c.score*c.size score,s.step_cost+c.step_cost step_cost,s.met+c.met met
   from pg_temp.match_states s join pg_temp.match_candidates c on (s.mask & c.mask)=0
   join app_private.intake_event_slots e on e.id=c.slot_id
   where c.size+coalesce((select sum(pc.size) from pg_temp.match_candidates pc where pc.id=any(s.chosen) and pc.slot_id=c.slot_id),0)
    +(select count(*) from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id where ta.active and dt.slot_id=c.slot_id)<=e.capacity
   order by s.mask|c.mask,s.step_cost+c.step_cost,(s.score+c.score*c.size) desc,s.met+c.met,s.chosen||c.id
  ) choices order by placed desc,step_cost,score desc,met,mask limit policy.beam_width;
  get diagnostics remaining=row_count;
  nodes:=nodes+remaining;
  if remaining=0 then exit; end if;
  truncate pg_temp.match_states;
  insert into pg_temp.match_states select * from pg_temp.match_next;
 end loop;
 select * into best from pg_temp.match_states order by placed desc,step_cost,score desc,met,mask limit 1;
 for candidate in select c.* from pg_temp.match_candidates c where c.id=any(best.chosen) order by c.slot_id,c.id loop
  -- Revalidate live application/entitlement/relationship facts immediately before writing.
  if candidate.size not between 4 and 6 or (select max(born)-min(born) from pg_temp.match_pool where i=any(candidate.indices))>8 then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  if exists(select 1 from pg_temp.match_pool p join app_private.intake_applications a on a.id=p.app_id join app_private.intake_event_slots e on e.id=candidate.slot_id
   where p.i=any(candidate.indices) and (not app_private.match_financially_eligible(a) or a.matching_status not in ('WAITING','REALLOCATING') or not a.input->'slotIds' ? e.id::text or not a.input->'regions' ? e.region_code or not e.published or e.starts_at<=clock_timestamp())) then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  if exists(select 1 from pg_temp.match_pool a join pg_temp.match_pool b on a.i<b.i join app_private.match_relations r on r.user_low=least(a.user_id,b.user_id) and r.user_high=greatest(a.user_id,b.user_id) where a.i=any(candidate.indices) and b.i=any(candidate.indices)) then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  select avg(app_private.match_pair_score(a.onboarding_snapshot,b.onboarding_snapshot,policy.weights)) into live_score
  from pg_temp.match_pool pa join pg_temp.match_pool pb on pa.i<pb.i join app_private.intake_applications a on a.id=pa.app_id join app_private.intake_applications b on b.id=pb.app_id where pa.i=any(candidate.indices) and pb.i=any(candidate.indices);
  if live_score<policy.minimum_score then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  insert into app_private.dining_tables(run_id,slot_id,score,validation) values(run_id,candidate.slot_id,live_score,jsonb_build_object('count',candidate.size,'ageGap',(select max(born)-min(born) from pg_temp.match_pool where i=any(candidate.indices)),'policyVersion',policy.version,'validatedAt',clock_timestamp())) returning id into chosen;
  insert into app_private.table_assignments(table_id,application_id,user_id,occupied_at)
   select chosen,p.app_id,p.user_id,tstzrange(e.starts_at,e.starts_at+make_interval(hours=>policy.duration_hours),'[)') from pg_temp.match_pool p join app_private.intake_event_slots e on e.id=candidate.slot_id where p.i=any(candidate.indices);
  update app_private.intake_applications set matching_status='CONFIRMED',match_checked_at=clock_timestamp() where id in(select app_id from pg_temp.match_pool where i=any(candidate.indices));
  insert into app_private.allocation_attempts(run_id,application_id,slot_id,step,reason)
   select run_id,p.app_id,candidate.slot_id,app_private.match_step(p.input,candidate.slot_id),case when app_private.match_step(p.input,candidate.slot_id)=0 then 'CONFIRMED' else 'REALLOCATED' end from pg_temp.match_pool p where p.i=any(candidate.indices);
  insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('confirmed:'||chosen,'TABLE_CONFIRMED',chosen,jsonb_build_object('tableId',chosen,'slotId',candidate.slot_id)) on conflict do nothing;
  assigned:=assigned+candidate.size;
 end loop;
 if total>n and assigned=0 then raise exception 'SEARCH_WINDOW_EXHAUSTED'; end if;
 for item in select a.* from app_private.intake_applications a join pg_temp.match_pool p on p.app_id=a.id where a.matching_status in ('WAITING','REALLOCATING') loop
  select exists(select 1 from app_private.intake_event_slots e where item.input->'slotIds' ? e.id::text and item.input->'regions' ? e.region_code and e.published and e.matches_at>clock_timestamp() and e.starts_at>clock_timestamp()) into future_slot;
  explanation:=case when total>n then 'NEXT_BATCH' when future_slot then 'WAITING_SELECTED_SLOT' else 'ALTERNATIVE_OFFERED' end;
  update app_private.intake_applications set matching_status=case when total>n or future_slot then 'REALLOCATING' else 'ALTERNATIVE_OFFERED' end,match_checked_at=clock_timestamp() where id=item.id;
  insert into app_private.allocation_attempts(run_id,application_id,slot_id,step,reason) values(run_id,item.id,job.slot_id,0,explanation);
  if total<=n and not future_slot then
   if item.membership_id is not null then perform app_private.membership_failure_extend(item.id); end if;
   insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('alternative:'||item.id,'ALTERNATIVE_OFFERED',item.id,jsonb_build_object('applicationId',item.id)) on conflict do nothing;
  end if;
 end loop;
 update app_private.match_runs set candidates=candidate_count,allocated=assigned,states_explored=nodes,finished_at=clock_timestamp(),elapsed_ms=extract(epoch from(clock_timestamp()-start_time))*1000 where id=run_id;
 update app_private.match_jobs set status=case when total>n then 'QUEUED' else 'DONE' end,due_at=case when total>n then clock_timestamp()+interval '1 second' else due_at end,attempts=case when total>n then 0 else attempts end,finished_at=case when total<=n then clock_timestamp() else null end,lease_until=null where id=job.id and token=claim_token;
 update app_private.match_job_attempts set outcome='COMPLETED',finished_at=clock_timestamp() where token=claim_token;
end $$;

create function app_private.matching_tick() returns int
language plpgsql security definer set search_path='' as $$
declare job app_private.match_jobs%rowtype; code text;
begin
 -- Overlapping cron invocations safely do no work while the prior tick holds its lock.
 if not pg_try_advisory_xact_lock(hashtextextended('matching-tick',0)) then return 0; end if;
 perform app_private.match_enqueue();
 job:=app_private.match_claim();
 if job.id is null then return 0; end if;
 begin
  perform app_private.match_process(job.id,job.token);
 exception when others then
  code:=case when sqlerrm in ('STALE_CLAIM','POLICY_MISSING','SEARCH_WINDOW_EXHAUSTED','FINAL_VALIDATION_FAILED') then sqlerrm when sqlstate='57014' then 'TIME_BUDGET' else 'MATCH_EXECUTION_FAILED' end;
  update app_private.match_jobs set status=case when attempts>=3 then 'EXCEPTION' else 'QUEUED' end,due_at=clock_timestamp()+interval '10 seconds',lease_until=null,last_error=code where id=job.id and token=job.token;
  update app_private.match_job_attempts set outcome='FAILED',error_code=code,finished_at=clock_timestamp() where token=job.token;
  if job.attempts>=3 then insert into app_private.match_exceptions(job_id,code) values(job.id,code) on conflict(job_id) do update set code=excluded.code; end if;
 end;
 return 1;
end $$;
revoke all on function app_private.match_process(uuid,uuid),app_private.matching_tick() from public,anon,authenticated,app_member_api;
select cron.schedule('serendipity-matching-tick','* * * * *','select app_private.matching_tick();');
