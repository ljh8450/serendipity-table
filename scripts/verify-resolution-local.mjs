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

const fixtures=[]
function prepare(n=3){
 const label=`resolution-race-${randomUUID()}`;seed(label,n);fixtures.push([label,n]);
 sql(`begin;
 insert into app_private.member_consents(user_id,document_id) select md5('${label}1user')::uuid,id from app_private.consent_documents where active on conflict do nothing;
 update app_private.intake_event_slots set refund_cutoff_at=clock_timestamp()+interval '1 day' where id=md5('${label}slot')::uuid;
 insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity,refund_cutoff_at)
 values(md5('${label}target')::uuid,now()+interval '14 days',now()-interval '1 day',now()+interval '1 day',now()+interval '2 days','gangnam','LOCAL RESOLUTION RACE',true,24,now()+interval '1 day');commit;`)
 if(n===3)sql('select app_private.matching_tick();')
 return label
}
function command(label,action,key=randomUUID()){
 const extra=action==='transfer'?`, 'slotId',md5('${label}target')::uuid`:action==='refund'?",'outcome','success'":''
 return `begin;set local statement_timeout='8s';select set_config('app.actor_id',md5('${label}1user')::uuid::text,true);set local role app_member_api;
 do $$ begin begin perform app_private.match_resolve(jsonb_build_object('applicationId',md5('${label}1app')::uuid,'requestKey','${key}','action','${action}'${extra}));
 exception when raise_exception then if sqlerrm not in ('RESOLUTION_CONFLICT','PAYMENT_CONFLICT') then raise;end if;end;end $$;select pg_sleep(0.15);commit;`
}
try{
 let label=prepare();await Promise.all([concurrentSQL(command(label,'transfer')),concurrentSQL(command(label,'refund'))]);
 if(sql(`select count(*) from app_private.match_resolutions where user_id=md5('${label}1user')::uuid and action in ('transfer','refund');`)!=='1')throw new Error('Transfer/refund race produced no single winner')
 if(sql(`select count(*) from app_private.intake_applications a where a.user_id=md5('${label}1user')::uuid and a.application_status='SUBMITTED' and a.payment_status='PAID';`)==='1' && sql(`select count(*) from app_private.refund_attempts where user_id=md5('${label}1user')::uuid and outcome='success';`)!=='0')throw new Error('Refund and transfer both retained value')
 label=prepare();const key=randomUUID();await Promise.all([concurrentSQL(command(label,'transfer',key)),concurrentSQL(command(label,'transfer',key))]);
 if(sql(`select count(*) from app_private.intake_applications where source_id=md5('${label}1app')::uuid;`)!=='1')throw new Error('Duplicate transfer application')
 label=prepare();await Promise.all([concurrentSQL(command(label,'store')),concurrentSQL(command(label,'transfer'))]);
 if(sql(`select count(*) from app_private.intake_applications where user_id=md5('${label}1user')::uuid and application_status='SUBMITTED' and payment_status='PAID';`)!=='1')throw new Error('Store/transfer lost or duplicated credit')
 label=prepare(4);await Promise.all([concurrentSQL('select app_private.matching_tick();'),concurrentSQL(command(label,'cancel'))]);
 if(sql(`select application_status from app_private.intake_applications where id=md5('${label}1app')::uuid;`)!=='CANCELED')throw new Error('Cancellation not committed')
 if(sql(`select count(*) from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.active and a.user_id=md5('${label}1user')::uuid;`)!=='0')throw new Error('Canceled participant retained assignment')
 if(sql(`select count(*) from app_private.dining_tables t where t.slot_id=md5('${label}slot')::uuid and t.status='CONFIRMED' and (select count(*) from app_private.table_assignments where table_id=t.id and active)<4;`)!=='0')throw new Error('Illegal three-person table retained')
 console.log(JSON.stringify({transferRefund:true,duplicateTransfer:true,storeTransfer:true,cancelWorker:true,localOnly:true}))
}finally{
 for(const [label,n] of fixtures){
  cleanup(label,n)
  sql(`delete from app_private.match_jobs where slot_id=md5('${label}target')::uuid;delete from app_private.intake_event_slots where id=md5('${label}target')::uuid;`)
 }
}
