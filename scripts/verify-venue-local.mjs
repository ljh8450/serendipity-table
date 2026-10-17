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

const label=`venue-proof-${randomUUID()}`
const operator=randomUUID()
const slot=`md5('${label}slot')::uuid`
try{
 const started=new Date().toISOString()
 seed(label,4)
 sql(`begin;update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["10_20"],"allergies":"","avoidedFoods":""}' where input->'slotIds' ? ${slot}::text;
 insert into auth.users(id) values('${operator}');insert into app_private.member_accounts(user_id,role) values('${operator}','operator');
 select app_private.matching_tick();select set_config('app.actor_id','${operator}',true);set local role app_member_api;
 select app_private.operations_venue_create(jsonb_build_object('requestKey',gen_random_uuid(),'slotId',${slot},'name','LOCAL CRON VENUE','address','LOCAL ONLY','mapUrl','https://example.test/map','reservationName','${label}','mealPriceKrw',15000,'seats',6,'rating',4.5,'reviewCount',40,'reviewUrl','https://example.test/review','verifiedAt',now()-interval '1 minute','reservationValidUntil',now()+interval '8 days','safeAllergies','[]'::jsonb,'safeAvoidedFoods','[]'::jsonb,'verificationNote','LOCAL FIXTURE','reservationConfirmed',true));commit;`)
 let assigned='0';const end=Date.now()+80000
 while(Date.now()<end){assigned=sql(`select count(*) from app_private.venue_allocations a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and a.active;`);if(assigned==='1')break;await new Promise(r=>setTimeout(r,1500))}
 if(assigned!=='1')throw new Error('Actual venue Cron did not allocate')
 if(sql(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-venue-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`)==='0')throw new Error('No actual venue Cron log')
 await Promise.all([concurrentSQL('select app_private.venue_tick();'),concurrentSQL('select app_private.venue_tick();')])
 if(sql(`select count(*) from app_private.venue_allocations a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot};`)!=='1')throw new Error('Parallel consumer duplicated allocation')
 await Promise.all([
  concurrentSQL('select app_private.venue_tick();'),
  concurrentSQL(`begin;select set_config('app.actor_id',md5('${label}1user')::uuid::text,true);set local role app_member_api;select app_private.match_resolve(jsonb_build_object('applicationId',md5('${label}1app')::uuid,'requestKey',gen_random_uuid(),'action','cancel'));commit;`)
 ])
 sql('select app_private.venue_tick();')
 if(sql(`select count(*) from app_private.venue_allocations a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and a.active;`)!=='0')throw new Error('Invalidated table retained reservation')
 console.log(JSON.stringify({actualVenueCron:true,browserNotRunning:true,parallelConsumers:true,cancelConsumer:true,noDuplicateReservation:true,localOnly:true}))
}finally{
 cleanup(label,4)
 sql(`delete from app_private.member_audit where actor_id='${operator}';delete from app_private.member_accounts where user_id='${operator}';delete from auth.users where id='${operator}';`)
}
