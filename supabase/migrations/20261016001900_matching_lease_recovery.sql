-- Record lease reclamation/exhaustion; do not retry dead workers forever.
create or replace function app_private.match_claim() returns app_private.match_jobs
language plpgsql security definer set search_path='' as $$
declare job app_private.match_jobs%rowtype;
begin
 select * into job from app_private.match_jobs where due_at<=clock_timestamp() and (status='QUEUED' or (status='RUNNING' and lease_until<clock_timestamp())) order by due_at,id for update skip locked limit 1;
 if job.id is null then return null; end if;
 if job.status='RUNNING' then
  update app_private.match_job_attempts set outcome='LEASE_EXPIRED',error_code='LEASE_EXPIRED',finished_at=clock_timestamp() where token=job.token and outcome is null;
  if job.attempts>=3 then
   update app_private.match_jobs set status='EXCEPTION',last_error='LEASE_EXPIRED',lease_until=null where id=job.id;
   insert into app_private.match_exceptions(job_id,code) values(job.id,'LEASE_EXPIRED') on conflict(job_id) do update set code=excluded.code;
   return null;
  end if;
 end if;
 update app_private.match_jobs set status='RUNNING',token=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',attempts=attempts+1 where id=job.id returning * into job;
 insert into app_private.match_job_attempts(job_id,token) values(job.id,job.token);
 return job;
end $$;
