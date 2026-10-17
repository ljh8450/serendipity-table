-- FDB-006/MAT-006: private directional choices and live actual attendance facts.
create table app_private.person_preferences (
 user_id uuid not null references auth.users(id) on delete cascade,
 target_user_id uuid not null references auth.users(id) on delete cascade,
 source_assignment_id uuid not null references app_private.table_assignments(id) on delete cascade,
 peer_assignment_id uuid not null references app_private.table_assignments(id) on delete cascade,
 value text not null check(value in ('LIKE','AVOID','NEUTRAL')),
 revision int not null check(revision>0),updated_at timestamptz not null default clock_timestamp(),
 primary key(user_id,target_user_id),check(user_id<>target_user_id)
);
create table app_private.preference_commands (
 user_id uuid not null references auth.users(id) on delete cascade,request_key uuid not null,
 assignment_id uuid not null references app_private.table_assignments(id) on delete cascade,
 peer_id uuid not null references app_private.table_assignments(id) on delete cascade,
 input jsonb not null,created_at timestamptz not null default clock_timestamp(),primary key(user_id,request_key)
);
alter table app_private.person_preferences enable row level security;
alter table app_private.preference_commands enable row level security;
revoke all on app_private.person_preferences,app_private.preference_commands from public,anon,authenticated,app_member_api;
create view app_private.actual_meetings as
 select least(x.user_id,y.user_id) user_low,greatest(x.user_id,y.user_id) user_high,t.id table_id,s.starts_at occurred_at
 from app_private.table_assignments x join app_private.table_assignments y on y.table_id=x.table_id and x.id<y.id
 join app_private.dining_tables t on t.id=x.table_id join app_private.intake_event_slots s on s.id=t.slot_id
 join app_private.intake_applications a on a.id=x.application_id join app_private.intake_applications b on b.id=y.application_id
 where x.active and y.active and t.status='CONFIRMED' and clock_timestamp()>=s.starts_at+interval '3 hours'
 and a.application_status='SUBMITTED' and b.application_status='SUBMITTED' and a.payment_status='PAID' and b.payment_status='PAID'
 and a.matching_status='CONFIRMED' and b.matching_status='CONFIRMED' and a.attendance_status='ATTENDED' and b.attendance_status='ATTENDED';
create view app_private.effective_person_preferences as
 select p.* from app_private.person_preferences p
 join app_private.table_assignments a on a.id=p.source_assignment_id and a.user_id=p.user_id
 join app_private.table_assignments b on b.id=p.peer_assignment_id and b.user_id=p.target_user_id and b.table_id=a.table_id
 where app_private.feedback_eligible(a.id,p.user_id) and app_private.feedback_eligible(b.id,p.target_user_id);
revoke all on app_private.actual_meetings,app_private.effective_person_preferences from public,anon,authenticated,app_member_api;

create function app_private.match_pair_blocked(a uuid,b uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.match_relations where user_low=least(a,b) and user_high=greatest(a,b))
 or exists(select 1 from app_private.effective_person_preferences p where p.value='AVOID' and ((p.user_id=a and p.target_user_id=b) or (p.user_id=b and p.target_user_id=a)))
$$;
create function app_private.match_pair_liked(a uuid,b uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.effective_person_preferences p where p.value='LIKE' and ((p.user_id=a and p.target_user_id=b) or (p.user_id=b and p.target_user_id=a)))
$$;
create function app_private.match_pair_met(a uuid,b uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.encounters where user_low=least(a,b) and user_high=greatest(a,b))
 or exists(select 1 from app_private.actual_meetings where user_low=least(a,b) and user_high=greatest(a,b))
$$;
create function app_private.preferences_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 return jsonb_build_object('events',coalesce((select jsonb_agg(item order by starts_at desc,id) from (
 select ta.id,s.starts_at,jsonb_build_object('assignmentId',ta.id,'startsAt',s.starts_at,'regionLabel',s.region_label,
 'feedbackSubmitted',exists(select 1 from app_private.event_feedback f where f.assignment_id=ta.id),
 'deadlineAt',s.starts_at+interval '3 hours 7 days','canEdit',clock_timestamp()<s.starts_at+interval '3 hours 7 days',
 'peers',coalesce((select jsonb_agg(jsonb_build_object('peerId',peer.id,'label','참가자 '||m.participant_no,
 'value',coalesce(p.value,'NEUTRAL'),'revision',coalesce(p.revision,0),'effective',exists(select 1 from app_private.effective_person_preferences ep where ep.user_id=p.user_id and ep.target_user_id=p.target_user_id and ep.value<>'NEUTRAL')) order by m.participant_no)
 from app_private.table_assignments peer join app_private.chat_rooms r on r.table_id=peer.table_id
 join app_private.chat_members m on m.room_id=r.id and m.user_id=peer.user_id and m.active
 left join app_private.person_preferences p on p.user_id=actor and p.target_user_id=peer.user_id
 where peer.table_id=ta.table_id and peer.user_id<>actor and app_private.feedback_eligible(peer.id,peer.user_id)),'[]'::jsonb)) item
 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id
 where ta.user_id=actor and app_private.feedback_eligible(ta.id,actor) order by s.starts_at desc,ta.id limit 20) q),'[]'::jsonb));
end $$;

-- Caller holds the exclusive matching fence. Only future confirmations are repaired.
create function app_private.preferences_repair(request_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare item record;
begin
 for item in select t.id,t.slot_id from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id
 where t.status='CONFIRMED' and s.starts_at>clock_timestamp() and exists(
 select 1 from app_private.table_assignments x join app_private.table_assignments y on x.table_id=y.table_id and x.id<y.id
 where x.table_id=t.id and x.active and y.active and app_private.match_pair_blocked(x.user_id,y.user_id)) order by t.id for update of t loop
  update app_private.dining_tables set status='INVALIDATED' where id=item.id;
  update app_private.intake_applications set matching_status='REALLOCATING' where id in(select application_id from app_private.table_assignments where table_id=item.id and active);
  update app_private.table_assignments set active=false where table_id=item.id;
  insert into app_private.match_jobs(job_key,slot_id,due_at) values('preference:'||request_id||':'||item.id,item.slot_id,clock_timestamp()) on conflict do nothing;
  insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload)
  values('preference:'||request_id||':'||item.id,'TABLE_INVALIDATED',item.id,jsonb_build_object('tableId',item.id)) on conflict do nothing;
 end loop;
end $$;
create function app_private.preferences_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();source_id uuid;peer_id uuid;req uuid;target_user uuid;expected int;prior app_private.preference_commands;current_revision int;deadline timestamptz;
begin
 if jsonb_typeof(payload) is distinct from 'object' then raise exception 'VALIDATION_ERROR';end if;
 if (select count(*) from jsonb_object_keys(payload))<>5 or not(payload ?& array['assignmentId','peerId','requestKey','value','revision'])
 or coalesce(payload->>'assignmentId','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'peerId','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'requestKey','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'value','') not in ('LIKE','AVOID','NEUTRAL')
 or jsonb_typeof(payload->'revision') is distinct from 'number' or coalesce(payload->>'revision','')!~'^[0-9]{1,9}$' then raise exception 'VALIDATION_ERROR';end if;
 source_id:=(payload->>'assignmentId')::uuid;peer_id:=(payload->>'peerId')::uuid;req:=(payload->>'requestKey')::uuid;expected:=(payload->>'revision')::int;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 if not app_private.feedback_eligible(source_id,actor) then raise exception 'FORBIDDEN';end if;
 select peer.user_id,s.starts_at+interval '3 hours 7 days' into target_user,deadline
 from app_private.table_assignments a join app_private.table_assignments peer on peer.table_id=a.table_id and peer.user_id<>actor
 join app_private.dining_tables t on t.id=a.table_id join app_private.intake_event_slots s on s.id=t.slot_id
 join app_private.chat_rooms r on r.table_id=t.id join app_private.chat_members m on m.room_id=r.id and m.user_id=peer.user_id and m.active
 where a.id=source_id and peer.id=peer_id and app_private.feedback_eligible(peer.id,peer.user_id);
 if target_user is null then raise exception 'FORBIDDEN';end if;
 select * into prior from app_private.preference_commands where user_id=actor and request_key=req;
 if prior.user_id is not null then
  if prior.input<>(payload-'requestKey') then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  return app_private.preferences_get();
 end if;
 if clock_timestamp()>=deadline then raise exception 'PREFERENCE_CLOSED';end if;
 select revision into current_revision from app_private.person_preferences where user_id=actor and target_user_id=target_user for update;
 if coalesce(current_revision,0)<>expected then raise exception 'PREFERENCE_CONFLICT';end if;
 insert into app_private.person_preferences(user_id,target_user_id,source_assignment_id,peer_assignment_id,value,revision)
 values(actor,target_user,source_id,peer_id,payload->>'value',expected+1)
 on conflict(user_id,target_user_id) do update set source_assignment_id=excluded.source_assignment_id,peer_assignment_id=excluded.peer_assignment_id,value=excluded.value,revision=excluded.revision,updated_at=clock_timestamp();
 insert into app_private.preference_commands(user_id,request_key,assignment_id,peer_id,input) values(actor,req,source_id,peer_id,payload-'requestKey');
 if payload->>'value'='AVOID' then perform app_private.preferences_repair(req);end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'PERSON_PREFERENCE_SAVE');
 return app_private.preferences_get();
end $$;
revoke all on function app_private.match_pair_blocked(uuid,uuid),app_private.match_pair_liked(uuid,uuid),app_private.match_pair_met(uuid,uuid),app_private.preferences_get(),app_private.preferences_repair(uuid),app_private.preferences_save(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.preferences_get(),app_private.preferences_save(jsonb) to app_member_api;

-- Keep base score/constraints; explicit likes are a separate tie breaker.
create or replace function app_private.match_process(job_id uuid,claim_token uuid) returns void
language plpgsql security definer set search_path='' as $$
declare job app_private.match_jobs%rowtype; policy app_private.matching_policy%rowtype; run_id uuid; total int; pool_limit int;
 depth int; nodes int:=0; candidate_count int; best record; candidate record; item record; table_uuid uuid; assigned int:=0; start_time timestamptz:=clock_timestamp();
 n int; future_slot boolean; remaining int; explanation text; live_score numeric;
begin
 -- A single global finalization fence also serializes relationship changes.
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 select * into job from app_private.match_jobs where id=job_id for update;
 if job.id is null or job.status<>'RUNNING' or job.token is distinct from claim_token or job.lease_until<=clock_timestamp() then raise exception 'STALE_CLAIM'; end if;
 select * into policy from app_private.matching_policy where active for share;
 if policy.version is null then raise exception 'POLICY_MISSING'; end if;
 if exists(select 1 from app_private.intake_event_slots where id=job.slot_id and published and starts_at<=clock_timestamp()) then raise exception 'MISSED_MATCH_WINDOW'; end if;
 if not exists(select 1 from app_private.intake_event_slots where id=job.slot_id and published and matches_at<=clock_timestamp() and starts_at>clock_timestamp()) then
  update app_private.match_jobs set status='DONE',finished_at=clock_timestamp(),lease_until=null where id=job.id;
  update app_private.match_job_attempts set outcome='SKIPPED',finished_at=clock_timestamp() where token=claim_token;
  return;
 end if;
 if exists(select 1 from app_private.intake_applications a where a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a)
 and a.input->'slotIds' ? job.slot_id::text and not app_private.match_profile_valid(a.onboarding_snapshot)) then raise exception 'PROFILE_REQUIRED';end if;
 insert into app_private.match_runs(job_id,token,policy_version,policy_snapshot,algorithm_version) values(job.id,claim_token,policy.version,to_jsonb(policy),'beam-feedback-v2') returning id into run_id;
 drop table if exists pg_temp.match_pool,pg_temp.match_pairs,pg_temp.match_candidates,pg_temp.match_states,pg_temp.match_next,pg_temp.match_best;
 create temporary table match_pool(i int primary key,app_id uuid unique,user_id uuid unique,born int,profile jsonb,input jsonb,submitted timestamptz) on commit drop;
 -- All due selected slots are considered together; future slots are never confirmed early.
 select count(distinct a.user_id) into total from app_private.intake_applications a
 where a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a)
 and app_private.match_profile_valid(a.onboarding_snapshot)
 and exists(select 1 from app_private.intake_event_slots e where e.published and e.matches_at<=clock_timestamp() and e.starts_at>clock_timestamp() and a.input->'slotIds' ? e.id::text and a.input->'regions' ? e.region_code);
 pool_limit:=policy.batch_size;
 if total>pool_limit and total-pool_limit between 1 and 3 then pool_limit:=total-4; end if;
 insert into pg_temp.match_pool
 select row_number() over(order by (a.onboarding_snapshot->>'birthYear')::int,a.submitted_at,a.id),a.id,a.user_id,(a.onboarding_snapshot->>'birthYear')::int,a.onboarding_snapshot,a.input,a.submitted_at
 from (select * from (select distinct on(a.user_id) a.* from app_private.intake_applications a
 where a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a)
 and app_private.match_profile_valid(a.onboarding_snapshot)
 and jsonb_typeof(a.onboarding_snapshot->'mbti')='array' and jsonb_typeof(a.onboarding_snapshot->'interests')='array'
 and jsonb_typeof(a.onboarding_snapshot->'traits')='array' and jsonb_typeof(a.onboarding_snapshot->'preferredTraits')='array'
 and exists(select 1 from app_private.intake_event_slots e where e.published and e.matches_at<=clock_timestamp() and e.starts_at>clock_timestamp() and a.input->'slotIds' ? e.id::text and a.input->'regions' ? e.region_code)
 order by a.user_id,a.submitted_at,a.id) picks
 order by (picks.onboarding_snapshot->>'birthYear')::int,picks.submitted_at,picks.id limit pool_limit offset ((job.attempts-1)*pool_limit)%greatest(total,1)) a
 order by (a.onboarding_snapshot->>'birthYear')::int,a.submitted_at,a.id;
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
 app_private.match_pair_blocked(a.user_id,b.user_id) blocked,app_private.match_pair_liked(a.user_id,b.user_id) liked,
 app_private.match_pair_met(a.user_id,b.user_id) met
 from pg_temp.match_pool a join pg_temp.match_pool b on a.i<b.i;
 create unique index on match_pairs(lo,hi);
 update app_private.match_runs set pair_snapshot=coalesce((select jsonb_agg(to_jsonb(p) order by lo,hi) from pg_temp.match_pairs p),'[]') where id=run_id;
 create temporary table match_candidates(id bigint generated always as identity primary key,slot_id uuid,indices int[],mask bigint,size int,score numeric,step_cost int,affinity int,met int) on commit drop;
 insert into pg_temp.match_candidates(slot_id,indices,mask,size,score,step_cost,affinity,met)
 with recursive combos as (
  select e.id slot_id,array[p.i] indices,(1::bigint << p.i) mask,p.i last_i,p.born youngest,p.born oldest,0::numeric score_sum,0::int affinity,0::int met,app_private.match_step(p.input,e.id) step_cost
  from pg_temp.match_pool p join app_private.intake_event_slots e on p.input->'slotIds' ? e.id::text and p.input->'regions' ? e.region_code
  where e.published and e.matches_at<=clock_timestamp() and e.starts_at>clock_timestamp()
  and not exists(select 1 from app_private.table_assignments ta where ta.user_id=p.user_id and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+make_interval(hours=>policy.duration_hours),'[)'))
  union all
  select c.slot_id,c.indices||p.i,c.mask | (1::bigint<<p.i),p.i,greatest(c.youngest,p.born),least(c.oldest,p.born),c.score_sum+pair.score,c.affinity+pair.affinity,c.met+pair.met,c.step_cost+app_private.match_step(p.input,c.slot_id)
  from combos c join pg_temp.match_pool p on p.i>c.last_i
  join app_private.intake_event_slots e on e.id=c.slot_id and p.input->'slotIds' ? e.id::text and p.input->'regions' ? e.region_code
  cross join lateral (select sum(mp.score) score,count(*) filter(where mp.liked)::int affinity,count(*) filter(where mp.met)::int met,bool_or(mp.blocked) blocked from pg_temp.match_pairs mp where mp.hi=p.i and mp.lo=any(c.indices)) pair
  where cardinality(c.indices)<6 and greatest(c.youngest,p.born)-least(c.oldest,p.born)<=8 and not pair.blocked
  and not exists(select 1 from app_private.table_assignments ta where ta.user_id=p.user_id and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+make_interval(hours=>policy.duration_hours),'[)'))
 )
 select slot_id,indices,mask,cardinality(indices),score_sum/(cardinality(indices)*(cardinality(indices)-1)/2),step_cost,affinity,met from combos
 where cardinality(indices) between 4 and 6 and score_sum/(cardinality(indices)*(cardinality(indices)-1)/2)>=policy.minimum_score
 order by slot_id,mask;
 get diagnostics candidate_count=row_count;
 if candidate_count>60000 then raise exception 'SEARCH_BUDGET'; end if;
 create temporary table match_states(mask bigint primary key,chosen bigint[],placed int,score numeric,step_cost int,affinity int,met int) on commit drop;
 create temporary table match_next(like match_states including all) on commit drop;
 insert into pg_temp.match_states values(0,'{}',0,0,0,0,0);
 create temporary table match_best on commit drop as select * from pg_temp.match_states;
 best:=row(0::bigint,'{}'::bigint[],0::int,0::numeric,0::int,0::int,0::int);
 for depth in 1..greatest(1,n/4) loop
  if clock_timestamp()-start_time>interval '30 seconds' then raise exception 'SEARCH_BUDGET';end if;
  truncate pg_temp.match_next;
  insert into pg_temp.match_next
  select mask,chosen,placed,score,step_cost,affinity,met from (select choices.*,row_number() over(partition by placed order by step_cost,score desc,affinity desc,met,mask) beam_rank from (
   select distinct on(s.mask|c.mask) s.mask|c.mask mask,s.chosen||c.id chosen,s.placed+c.size placed,s.score+c.score*c.size score,s.step_cost+c.step_cost step_cost,s.affinity+c.affinity affinity,s.met+c.met met
   from pg_temp.match_states s join pg_temp.match_candidates c on (s.mask & c.mask)=0
   join app_private.intake_event_slots e on e.id=c.slot_id
   where c.size+coalesce((select sum(pc.size) from pg_temp.match_candidates pc where pc.id=any(s.chosen) and pc.slot_id=c.slot_id),0)
    +(select count(*) from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id where ta.active and dt.slot_id=c.slot_id)<=e.capacity
   order by s.mask|c.mask,s.step_cost+c.step_cost,(s.score+c.score*c.size) desc,(s.affinity+c.affinity) desc,s.met+c.met,s.chosen||c.id
  ) choices) diverse where beam_rank<=greatest(1,policy.beam_width/(depth*2+1)) order by beam_rank,placed desc,step_cost,score desc,affinity desc,met,mask limit policy.beam_width;
  get diagnostics remaining=row_count;
  nodes:=nodes+remaining;
  if remaining=0 then exit; end if;
  truncate pg_temp.match_states;
  insert into pg_temp.match_states select * from pg_temp.match_next;
  insert into pg_temp.match_best select * from pg_temp.match_states;
 end loop;
 select * into best from pg_temp.match_best order by placed desc,step_cost,score desc,affinity desc,met,mask limit 1;
 for candidate in select c.* from pg_temp.match_candidates c where c.id=any(best.chosen) order by c.slot_id,c.id loop
  -- Revalidate live application/entitlement/relationship facts immediately before writing.
  if candidate.size not between 4 and 6 or (select max(born)-min(born) from pg_temp.match_pool where i=any(candidate.indices))>8 then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  if exists(select 1 from pg_temp.match_pool p join app_private.intake_applications a on a.id=p.app_id join app_private.intake_event_slots e on e.id=candidate.slot_id
   where p.i=any(candidate.indices) and (not app_private.match_financially_eligible(a) or a.matching_status not in ('WAITING','REALLOCATING') or not a.input->'slotIds' ? e.id::text or not a.input->'regions' ? e.region_code or not e.published or e.starts_at<=clock_timestamp())) then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  if exists(select 1 from pg_temp.match_pool a join pg_temp.match_pool b on a.i<b.i where a.i=any(candidate.indices) and b.i=any(candidate.indices) and app_private.match_pair_blocked(a.user_id,b.user_id)) then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  select avg(app_private.match_pair_score(a.onboarding_snapshot,b.onboarding_snapshot,policy.weights)) into live_score
  from pg_temp.match_pool pa join pg_temp.match_pool pb on pa.i<pb.i join app_private.intake_applications a on a.id=pa.app_id join app_private.intake_applications b on b.id=pb.app_id where pa.i=any(candidate.indices) and pb.i=any(candidate.indices);
  if live_score<policy.minimum_score then raise exception 'FINAL_VALIDATION_FAILED'; end if;
  insert into app_private.dining_tables(run_id,slot_id,score,validation) values(run_id,candidate.slot_id,live_score,jsonb_build_object('count',candidate.size,'ageGap',(select max(born)-min(born) from pg_temp.match_pool where i=any(candidate.indices)),'policyVersion',policy.version,'validatedAt',clock_timestamp())) returning id into table_uuid;
  insert into app_private.table_assignments(table_id,application_id,user_id,occupied_at)
   select table_uuid,p.app_id,p.user_id,tstzrange(e.starts_at,e.starts_at+make_interval(hours=>policy.duration_hours),'[)') from pg_temp.match_pool p join app_private.intake_event_slots e on e.id=candidate.slot_id where p.i=any(candidate.indices);
  insert into app_private.member_audit(actor_id,action) select user_id,'MATCH_CONFIRMED' from pg_temp.match_pool where i=any(candidate.indices);
  update app_private.intake_applications set matching_status='CONFIRMED',match_checked_at=clock_timestamp() where id in(select app_id from pg_temp.match_pool where i=any(candidate.indices));
  insert into app_private.allocation_attempts(run_id,application_id,slot_id,step,reason)
   select run_id,p.app_id,(select e.id from app_private.intake_event_slots e where p.input->'slotIds' ? e.id::text order by e.starts_at,e.id limit 1),0,'SOURCE_REPLANNED' from pg_temp.match_pool p where p.i=any(candidate.indices) and app_private.match_step(p.input,candidate.slot_id)>0;
  insert into app_private.allocation_attempts(run_id,application_id,slot_id,step,reason)
   select run_id,p.app_id,candidate.slot_id,app_private.match_step(p.input,candidate.slot_id),case when app_private.match_step(p.input,candidate.slot_id)=0 then 'CONFIRMED' else 'REALLOCATED' end from pg_temp.match_pool p where p.i=any(candidate.indices);
  insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('confirmed:'||table_uuid,'TABLE_CONFIRMED',table_uuid,jsonb_build_object('tableId',table_uuid,'slotId',candidate.slot_id)) on conflict do nothing;
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
 update app_private.match_jobs set last_error=null,status=case when total>n then 'QUEUED' else 'DONE' end,due_at=case when total>n then clock_timestamp()+interval '1 second' else due_at end,attempts=case when total>n then 0 else attempts end,finished_at=case when total<=n then clock_timestamp() else null end,lease_until=null where id=job.id and token=claim_token;
 update app_private.match_job_attempts set outcome='COMPLETED',finished_at=clock_timestamp() where token=claim_token;
end $$;




create or replace function app_private.cancel_table_repair(app_id uuid,request_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare t app_private.dining_tables%rowtype; e app_private.intake_event_slots%rowtype;
 policy app_private.matching_policy%rowtype; size int; gap int; live_score numeric; valid boolean;
begin
 select dt.* into t from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id where ta.application_id=app_id and ta.active for update of dt;
 if t.id is null then return; end if;
 select * into e from app_private.intake_event_slots where id=t.slot_id for share;
 select * into policy from app_private.matching_policy where active for share;
 update app_private.table_assignments set active=false where application_id=app_id and active;
 select count(*),max((a.onboarding_snapshot->>'birthYear')::int)-min((a.onboarding_snapshot->>'birthYear')::int),
 bool_and(app_private.match_financially_eligible(a) and a.input->'slotIds' ? e.id::text and a.input->'regions' ? e.region_code)
 into size,gap,valid from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.table_id=t.id and ta.active;
 select avg(app_private.match_pair_score(a.onboarding_snapshot,b.onboarding_snapshot,policy.weights)) into live_score
 from app_private.table_assignments x join app_private.table_assignments y on x.table_id=y.table_id and x.id<y.id
 join app_private.intake_applications a on a.id=x.application_id join app_private.intake_applications b on b.id=y.application_id
 where x.table_id=t.id and x.active and y.active;
 valid:=coalesce(valid,false) and size between 4 and 6 and gap<=8 and live_score>=policy.minimum_score and e.published and e.starts_at>clock_timestamp()
 and not exists(select 1 from app_private.table_assignments x join app_private.table_assignments y on x.table_id=y.table_id and x.id<y.id
 where x.table_id=t.id and x.active and y.active and app_private.match_pair_blocked(x.user_id,y.user_id));
 if valid then
  update app_private.dining_tables set score=live_score,validation=jsonb_build_object('count',size,'ageGap',gap,'policyVersion',policy.version,'validatedAt',clock_timestamp()) where id=t.id;
 else
  update app_private.dining_tables set status='INVALIDATED' where id=t.id;
  update app_private.intake_applications set matching_status='REALLOCATING',match_checked_at=clock_timestamp() where id in(select application_id from app_private.table_assignments where table_id=t.id and active);
  update app_private.table_assignments set active=false where table_id=t.id;
  insert into app_private.match_jobs(job_key,slot_id,due_at) values('cancel:'||request_id,t.slot_id,clock_timestamp());
 end if;
 insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload)
 values('cancel:'||request_id,case when valid then 'TABLE_UPDATED' else 'TABLE_INVALIDATED' end,t.id,jsonb_build_object('tableId',t.id)) on conflict do nothing;
end $$;

-- Restoring attendance can reactivate an existing AVOID: repair under the same exclusive fence.
create or replace function app_private.operations_attendance_review(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();target uuid;req uuid;outcome text;note text;prior app_private.attendance_actions;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>4 or not(payload ?& array['assignmentId','requestKey','outcome','reason'])
 or coalesce(payload->>'assignmentId','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'requestKey','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or coalesce(payload->>'outcome','') not in ('ATTENDED','NO_SHOW') or jsonb_typeof(payload->'reason') is distinct from 'string'
 or length(btrim(payload->>'reason')) not between 5 and 500 then raise exception 'VALIDATION_ERROR';end if;
 target:=(payload->>'assignmentId')::uuid;req:=(payload->>'requestKey')::uuid;outcome:=payload->>'outcome';note:=btrim(payload->>'reason');
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 if not exists(select 1 from app_private.attendance_records r join app_private.table_assignments ta on ta.id=r.assignment_id
 join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_applications a on a.id=ta.application_id
 where r.assignment_id=target and r.review_status<>'NONE' and r.closed_at is not null and ta.active and t.status='CONFIRMED'
 and a.application_status='SUBMITTED' and a.matching_status='CONFIRMED') then raise exception 'ATTENDANCE_CONFLICT';end if;
 select * into prior from app_private.attendance_actions where actor_id=actor and request_key=req;
 if prior.id is not null then
  if prior.assignment_id<>target or prior.action<>outcome or prior.reason<>note then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  return app_private.operations_attendance_get();
 end if;
 update app_private.attendance_records set review_status=outcome where assignment_id=target;
 update app_private.intake_applications a set attendance_status=outcome from app_private.table_assignments ta where ta.id=target and a.id=ta.application_id;
 if outcome='ATTENDED' then perform app_private.preferences_repair(req);end if;
 insert into app_private.attendance_actions(assignment_id,actor_id,request_key,action,reason) values(target,actor,req,outcome,note);
 insert into app_private.member_audit(actor_id,action) values(actor,'ATTENDANCE_REVIEW');
 return app_private.operations_attendance_get();
end $$;
