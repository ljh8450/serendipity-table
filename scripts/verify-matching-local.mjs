// Local-only real Cron/concurrency proof. No browsers or remote credentials are used.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { randomUUID } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
process.chdir(fileURLToPath(new URL('..', import.meta.url)))
const container = 'supabase_db_serendipity-table'
const args = ['exec','-i',container,'psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const sql = query => execFileSync('docker',args,{input:query,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
const asyncExec = promisify(execFile)
const concurrentSQL = query => asyncExec('docker',[...args,'-c',query],{encoding:'utf8',maxBuffer:1024*1024})
const prefix = readFileSync('supabase/tests/matching_permissions.sql','utf8').replace(/^\uFEFF/,'').split('do $$ declare count_n')[0]
const active = new Set()
function seed(label,n) {
  if(!/^[a-z0-9-]+$/.test(label))throw new Error('Invalid generated fixture label')
  sql(prefix+`select pg_temp.match_fixture('${label}',${n});commit;`)
  active.add(label)
}
function stats(label) {
  return JSON.parse(sql(`select jsonb_build_object('assigned',(select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=md5('${label}slot')::uuid and a.active),'tables',(select count(*) from app_private.dining_tables where slot_id=md5('${label}slot')::uuid and status='CONFIRMED'),'completed',(select count(*) from app_private.match_jobs where slot_id=md5('${label}slot')::uuid and status='DONE'),'maxMs',(select max(elapsed_ms) from app_private.match_runs r join app_private.match_jobs j on j.id=r.job_id where j.slot_id=md5('${label}slot')::uuid));`))
}
function cleanup(label,n) {
  const ids=Array.from({length:n},(_,i)=>`md5('${label}${i+1}user')::uuid`).join(',')
  const slot=`md5('${label}slot')::uuid`
  sql(`begin;
    select pg_advisory_xact_lock(hashtextextended('matching-state',0));
    delete from app_private.match_relations where user_low in(${ids}) or user_high in(${ids});
    delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(select id from app_private.intake_applications where user_id in(${ids}));
    delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id in(${ids}));
    delete from app_private.table_assignments where user_id in(${ids});
    delete from app_private.dining_tables where slot_id=${slot};
    delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});
    delete from app_private.match_jobs where slot_id=${slot};
    delete from app_private.refund_attempts where user_id in(${ids});
    delete from app_private.payment_attempts where user_id in(${ids});
    delete from app_private.intake_applications where user_id in(${ids});
    delete from app_private.member_audit where actor_id in(${ids});
    delete from app_private.member_accounts where user_id in(${ids});
    delete from auth.users where id in(${ids});
    delete from app_private.intake_event_slots where id=${slot};commit;`)
  active.delete(label)
}
const labels = {cron:`cron-proof-${randomUUID()}`,parallel:`parallel-proof-${randomUUID()}`,relation:`relation-proof-${randomUUID()}`,refund:`refund-proof-${randomUUID()}`}
try {
  if(sql("select count(*) from cron.job where jobname='serendipity-matching-tick' and active;")!=='1')throw new Error('Project Cron not enabled')
  // Refuse to mix the proof with unrelated overdue application processing.
  if(sql("select count(*) from app_private.intake_applications a where a.matching_status in ('WAITING','REALLOCATING') and app_private.match_financially_eligible(a) and exists(select 1 from app_private.intake_event_slots e where e.published and e.matches_at<=clock_timestamp() and a.input->'slotIds' ? e.id::text);")!=='0')throw new Error('Unrelated overdue matching inputs exist')
  const started = new Date().toISOString()
  seed(labels.cron,8)
  const end = Date.now()+80000
  let cronState
  while(Date.now()<end){
    cronState=stats(labels.cron)
    if(cronState.completed===1)break
    await new Promise(resolve=>setTimeout(resolve,1500))
  }
  if(cronState?.assigned!==8 || cronState?.tables!==2)throw new Error('Real Cron did not automatically confirm 8 as 4+4')
  const cronLog=Number(sql(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-matching-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`))
  if(!cronLog)throw new Error('No successful actual Cron execution log')
  cleanup(labels.cron,8)
  seed(labels.parallel,4)
  await Promise.all([concurrentSQL('select app_private.matching_tick();'),concurrentSQL('select app_private.matching_tick();')])
  const parallelState=stats(labels.parallel)
  if(parallelState.assigned!==4 || parallelState.tables!==1)throw new Error('Concurrent workers duplicated/lost assignments')
  cleanup(labels.parallel,4)
  seed(labels.relation,4)
  await Promise.all([
    concurrentSQL('begin;select app_private.matching_tick();select pg_sleep(0.5);commit;'),
    concurrentSQL(`insert into app_private.match_relations(user_low,user_high,reason) values(least(md5('${labels.relation}1user')::uuid,md5('${labels.relation}2user')::uuid),greatest(md5('${labels.relation}1user')::uuid,md5('${labels.relation}2user')::uuid),'report');`)
  ])
  if(stats(labels.relation).assigned!==0)throw new Error('Concurrent report left an unsafe confirmed table')
  cleanup(labels.relation,4)
  seed(labels.refund,4)
  await Promise.all([
    concurrentSQL('begin;select app_private.matching_tick();select pg_sleep(0.5);commit;'),
    concurrentSQL(`begin;select set_config('app.actor_id',md5('${labels.refund}1user')::uuid::text,true);set local role app_member_api;do $$ begin begin perform app_private.mock_refund(jsonb_build_object('applicationId',md5('${labels.refund}1app')::uuid,'requestKey',gen_random_uuid(),'outcome','success'));exception when raise_exception then if sqlerrm<>'PAYMENT_CONFLICT' then raise;end if;end;end $$;commit;`)
  ])
  const unsafe=Number(sql(`select count(*) from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.active and a.input->'slotIds' ? md5('${labels.refund}slot')::uuid::text and not app_private.match_financially_eligible(a);`))
  if(unsafe)throw new Error('Refund race confirmed an ineligible participant')
  cleanup(labels.refund,4)
  mkdirSync('.local',{recursive:true})
  const result={actualCron:true,browserNotRunning:true,cronLogCount:cronLog,automaticTables:cronState.tables,automaticAssigned:cronState.assigned,maxMs:cronState.maxMs,concurrentWorker:true,concurrentReport:true,concurrentRefund:true,fixturesCleaned:true}
  writeFileSync('.local/matching-proof.json',JSON.stringify(result,null,2))
  console.log(JSON.stringify(result))
} finally {
  for(const label of active)cleanup(label,label===labels.cron?8:4)
}
