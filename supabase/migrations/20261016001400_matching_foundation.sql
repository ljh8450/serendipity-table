-- MAT-005: database-owned queue, immutable matching facts and transactional outbox.
create extension if not exists btree_gist with schema extensions;
create extension if not exists pg_cron;
create table app_private.matching_policy (
 version text primary key, minimum_score numeric not null check(minimum_score between 0 and 100),
 batch_size int not null check(batch_size between 4 and 16), beam_width int not null check(beam_width between 1 and 64),
 duration_hours int not null check(duration_hours between 1 and 6), active boolean not null default false,
 weights jsonb not null
);
create unique index matching_policy_active on app_private.matching_policy(active) where active;
insert into app_private.matching_policy values('match-v1',35,16,64,3,true,'{"age":40,"gender":25,"mbti":15,"interests":10,"traits":10}');
create table app_private.match_jobs (
 id uuid primary key default gen_random_uuid(),job_key text not null unique,
 slot_id uuid not null references app_private.intake_event_slots(id) on delete cascade,
 due_at timestamptz not null,status text not null default 'QUEUED' check(status in ('QUEUED','RUNNING','DONE','EXCEPTION')),
 token uuid,lease_until timestamptz,attempts int not null default 0, last_error text,created_at timestamptz not null default now(),finished_at timestamptz
);
create index matching_due on app_private.match_jobs(due_at) where status in ('QUEUED','RUNNING');
create table app_private.match_job_attempts (
 id bigint generated always as identity primary key,job_id uuid not null references app_private.match_jobs(id) on delete cascade,
 token uuid not null,started_at timestamptz not null default clock_timestamp(),finished_at timestamptz,outcome text,error_code text
);
create table app_private.match_runs (
 id uuid primary key default gen_random_uuid(),job_id uuid not null references app_private.match_jobs(id) on delete cascade,
 token uuid not null unique,policy_version text not null references app_private.matching_policy(version),policy_snapshot jsonb not null,
 input_snapshot jsonb not null default '[]',started_at timestamptz not null default clock_timestamp(),finished_at timestamptz,
 candidates int not null default 0,allocated int not null default 0,states_explored int not null default 0,elapsed_ms int
);
create table app_private.dining_tables (
 id uuid primary key default gen_random_uuid(),run_id uuid not null references app_private.match_runs(id),
 slot_id uuid not null references app_private.intake_event_slots(id),
 status text not null default 'CONFIRMED' check(status in ('CONFIRMED','INVALIDATED')),
 score numeric not null,validation jsonb not null,created_at timestamptz not null default clock_timestamp()
);
create table app_private.table_assignments (
 id uuid primary key default gen_random_uuid(),table_id uuid not null references app_private.dining_tables(id),
 application_id uuid not null references app_private.intake_applications(id),user_id uuid not null references auth.users(id) on delete cascade,
 occupied_at tstzrange not null,active boolean not null default true,
 exclude using gist(user_id extensions.gist_uuid_ops with =,occupied_at with &&) where(active)
);
create unique index one_active_application_assignment on app_private.table_assignments(application_id) where active;
create table app_private.match_relations (
 id uuid primary key default gen_random_uuid(),user_low uuid not null references auth.users(id) on delete cascade,
 user_high uuid not null references auth.users(id) on delete cascade,reason text not null check(reason in ('block','report','dislike')),
 created_at timestamptz not null default clock_timestamp(),check(user_low<user_high),unique(user_low,user_high,reason)
);
create table app_private.encounters (
 user_low uuid not null references auth.users(id) on delete cascade,user_high uuid not null references auth.users(id) on delete cascade,
 source_key text not null,occurred_at timestamptz not null,check(user_low<user_high),primary key(user_low,user_high,source_key)
);
create table app_private.allocation_attempts (
 id bigint generated always as identity primary key,run_id uuid not null references app_private.match_runs(id),
 application_id uuid not null references app_private.intake_applications(id),slot_id uuid references app_private.intake_event_slots(id),
 step int not null check(step between 0 and 4),reason text not null,created_at timestamptz not null default clock_timestamp()
);
create table app_private.match_outbox (
 id uuid primary key default gen_random_uuid(),event_key text not null unique,
 event_type text not null check(event_type in ('TABLE_CONFIRMED','TABLE_INVALIDATED','ALTERNATIVE_OFFERED')),
 aggregate_id uuid not null,payload jsonb not null,created_at timestamptz not null default clock_timestamp(),
 status text not null default 'PENDING' check(status in ('PENDING','DELIVERED','EXCEPTION'))
);
create table app_private.match_exceptions (
 id uuid primary key default gen_random_uuid(),job_id uuid not null unique references app_private.match_jobs(id) on delete cascade,
 code text not null,created_at timestamptz not null default clock_timestamp()
);
alter table app_private.intake_applications add column match_checked_at timestamptz;
do $$ declare name text; begin
 foreach name in array array['matching_policy','match_jobs','match_job_attempts','match_runs','dining_tables','table_assignments','match_relations','encounters','allocation_attempts','match_outbox','match_exceptions'] loop
  execute format('alter table app_private.%I enable row level security',name);
  execute format('revoke all on app_private.%I from public,anon,authenticated,app_member_api',name);
 end loop;
end $$;

create function app_private.match_enqueue() returns void
language sql security definer set search_path='' as $$
 insert into app_private.match_jobs(job_key,slot_id,due_at)
 select 'slot:'||id::text,id,matches_at from app_private.intake_event_slots where published and matches_at is not null and starts_at>clock_timestamp()
 on conflict(job_key) do nothing
$$;
create function app_private.match_claim() returns app_private.match_jobs
language plpgsql security definer set search_path='' as $$
declare job app_private.match_jobs%rowtype;
begin
 select * into job from app_private.match_jobs where due_at<=clock_timestamp() and (status='QUEUED' or (status='RUNNING' and lease_until<clock_timestamp())) order by due_at,id for update skip locked limit 1;
 if job.id is null then return null; end if;
 update app_private.match_jobs set status='RUNNING',token=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',attempts=attempts+1 where id=job.id returning * into job;
 insert into app_private.match_job_attempts(job_id,token) values(job.id,job.token);
 return job;
end $$;

create function app_private.match_financially_eligible(a app_private.intake_applications) returns boolean
language sql stable security definer set search_path='' as $$
 select a.application_status='SUBMITTED' and a.payment_status='PAID'
 and exists(select 1 from app_private.member_accounts where user_id=a.user_id and not restricted)
 and case when a.membership_id is not null then app_private.membership_covers(a.membership_id,a.input->'slotIds')
 else exists(select 1 from app_private.payment_attempts p where p.application_id=a.id and p.outcome='success') end
$$;
create function app_private.match_step(app_input jsonb,slot uuid) returns int
language sql stable security definer set search_path='' as $$
 select case when target.id=origin.id then 0
 when (target.starts_at at time zone 'Asia/Seoul')::date=(origin.starts_at at time zone 'Asia/Seoul')::date and target.region_code=origin.region_code then 1
 when (target.starts_at at time zone 'Asia/Seoul')::date=(origin.starts_at at time zone 'Asia/Seoul')::date then 2
 when target.region_code=origin.region_code then 3 else 4 end
 from app_private.intake_event_slots target cross join lateral
 (select e.* from app_private.intake_event_slots e where app_input->'slotIds' ? e.id::text order by e.starts_at,e.id limit 1) origin where target.id=slot
$$;
create function app_private.match_pair_score(a jsonb,b jsonb,weights jsonb) returns numeric
language plpgsql immutable set search_path='' as $$
declare interest numeric; mbti numeric; trait numeric; ca int; cb int; common int;
begin
 select count(*) into ca from jsonb_array_elements_text(a->'interests');
 select count(*) into cb from jsonb_array_elements_text(b->'interests');
 select count(*) into common from (select jsonb_array_elements_text(a->'interests') intersect select jsonb_array_elements_text(b->'interests')) x;
 interest:=case when ca+cb-common=0 then 0 else common::numeric/(ca+cb-common) end;
 select coalesce(max((case when substr(x,1,1)=substr(y,1,1) then 1 else 0 end+case when substr(x,2,1)=substr(y,2,1) then 1 else 0 end+case when substr(x,3,1)=substr(y,3,1) then 1 else 0 end+case when substr(x,4,1)=substr(y,4,1) then 1 else 0 end)::numeric/4),0) into mbti from jsonb_array_elements_text(a->'mbti') x cross join jsonb_array_elements_text(b->'mbti') y;
 trait:=(case when exists(select 1 from jsonb_array_elements_text(a->'preferredTraits') x where b->'traits' ? x or (x='similar' and a->'traits' ?| array(select jsonb_array_elements_text(b->'traits'))) or (x='different' and not a->'traits' ?| array(select jsonb_array_elements_text(b->'traits')))) then 1 else 0 end+
 case when exists(select 1 from jsonb_array_elements_text(b->'preferredTraits') x where a->'traits' ? x or (x='similar' and b->'traits' ?| array(select jsonb_array_elements_text(a->'traits'))) or (x='different' and not b->'traits' ?| array(select jsonb_array_elements_text(a->'traits')))) then 1 else 0 end)::numeric/2;
 return (weights->>'age')::numeric*greatest(0,1-abs((a->>'birthYear')::int-(b->>'birthYear')::int)::numeric/8)
 +(weights->>'gender')::numeric*case when a->>'gender'<>b->>'gender' then 1 else 0 end
 +(weights->>'mbti')::numeric*mbti+(weights->>'interests')::numeric*interest+(weights->>'traits')::numeric*trait;
end $$;

-- Global relationship fence is acquired before reading the candidate snapshot.
create function app_private.match_relation_fence() returns trigger
language plpgsql security definer set search_path='' as $$
declare table_row record; slot uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 if tg_op='INSERT' then
  for table_row in select distinct a.table_id from app_private.table_assignments a join app_private.table_assignments b on a.table_id=b.table_id where a.active and b.active and a.user_id=new.user_low and b.user_id=new.user_high loop
   update app_private.dining_tables set status='INVALIDATED' where id=table_row.table_id returning slot_id into slot;
   update app_private.intake_applications set matching_status='REALLOCATING' where id in (select application_id from app_private.table_assignments where table_id=table_row.table_id and active);
   update app_private.table_assignments set active=false where table_id=table_row.table_id;
   insert into app_private.match_jobs(job_key,slot_id,due_at) values('relation:'||new.id||':'||table_row.table_id,slot,clock_timestamp()) on conflict do nothing;
   insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload) values('invalidated:'||new.id||':'||table_row.table_id,'TABLE_INVALIDATED',table_row.table_id,jsonb_build_object('tableId',table_row.table_id)) on conflict do nothing;
  end loop;
  return new;
 end if;
 return old;
end $$;
create trigger match_relation_fence before insert or delete on app_private.match_relations for each row execute function app_private.match_relation_fence();

revoke all on function app_private.match_enqueue(),app_private.match_claim(),app_private.match_financially_eligible(app_private.intake_applications),app_private.match_step(jsonb,uuid),app_private.match_pair_score(jsonb,jsonb,jsonb),app_private.match_relation_fence() from public,anon,authenticated,app_member_api;
