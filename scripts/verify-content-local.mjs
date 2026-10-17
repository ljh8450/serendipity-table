// Local DB/Cron/concurrency proof, without a browser or external push subscription.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { randomUUID } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
process.chdir(fileURLToPath(new URL('..', import.meta.url)))
mkdirSync('.local',{recursive:true})
const args = ['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const db = q => execFileSync('docker', args, { input:q,encoding:'utf8',stdio:['pipe','pipe','pipe'] }).trim()
const run = promisify(execFile)
const parallel = q => run('docker',[...args,'-c',q],{encoding:'utf8'})
const label = `content-proof-${randomUUID()}`,operator = `content-op-${randomUUID()}`
const slot = `md5('${label}slot')::uuid`, users = Array.from({length:4},(_,i)=>`md5('${label}${i+1}user')::uuid`).join(',')
const op = `md5('${operator}')::uuid`
const prefix = readFileSync('supabase/tests/content_permissions.sql','utf8').split('do $$ declare s uuid;')[0].replaceAll("'venue-operator'",`'${operator}'`)
const status = kind => db(`select j.status from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where t.slot_id=${slot} and j.kind='${kind}';`)
async function waitDone(kind) {
  const end = Date.now()+80000
  while(Date.now()<end) { if(status(kind)==='DONE')return;await new Promise(r=>setTimeout(r,1500)) }
  throw new Error(`Actual ${kind} Cron did not complete`)
}
try {
  const started = new Date().toISOString()
  db(prefix+`select pg_temp.content_fixture('${label}',interval '23 hours');commit;`)
  await waitDone('D1')
  db(`begin;select pg_advisory_xact_lock(hashtextextended('content-tick',0));select pg_advisory_xact_lock(hashtextextended('matching-state',0));
   update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '1 second',closes_at=least(closes_at,clock_timestamp()-interval '2 minutes'),matches_at=least(matches_at,clock_timestamp()-interval '1 minute') where id=${slot};
   update app_private.content_jobs j set scheduled_at=s.starts_at,due_at=s.starts_at from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id where j.table_id=t.id and t.slot_id=${slot} and j.kind='START';commit;`)
  await waitDone('START')
  const before = db(`select count(*) from app_private.chat_messages m join app_private.chat_rooms r on r.id=m.room_id join app_private.dining_tables t on t.id=r.table_id where t.slot_id=${slot};`)
  await Promise.all([parallel('select app_private.content_tick();'),parallel('select app_private.content_tick();')])
  const after = db(`select count(*) from app_private.chat_messages m join app_private.chat_rooms r on r.id=m.room_id join app_private.dining_tables t on t.id=r.table_id where t.slot_id=${slot};`)
  if(before!==after)throw new Error('Concurrent content duplicated messages')
  await Promise.all([
    parallel('select app_private.content_tick();'),
    parallel(`insert into app_private.match_relations(user_low,user_high,reason) values(least(md5('${label}1user')::uuid,md5('${label}2user')::uuid),greatest(md5('${label}1user')::uuid,md5('${label}2user')::uuid),'report');`),
  ])
  db('select app_private.content_tick();')
  if(db(`select count(*) from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id where t.slot_id=${slot} and ta.active;`)!=='0')throw new Error('Report did not revoke content access')
  const room = db(`select r.id from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=${slot};`)
  db(`begin;select set_config('app.actor_id',md5('${label}1user')::uuid::text,true);set local role app_member_api;
   do $$ begin begin perform app_private.chat_get(jsonb_build_object('roomId','${room}','before',null));raise exception 'revoked chat accepted';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;rollback;`)
  const logs = Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-content-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`))
  if(logs<2)throw new Error('Missing actual content Cron logs')
  const result={actualD1Cron:true,actualStartCron:true,noBrowserStarted:true,parallelConsumersUnique:true,reportPostingRace:true,accessRevoked:true,cronLogs:logs,localOnly:true}
  writeFileSync('.local/content-proof.json',JSON.stringify(result));console.log(JSON.stringify(result))
} finally {
  db(`begin;select pg_advisory_xact_lock(hashtextextended('content-tick',0));select pg_advisory_xact_lock(hashtextextended('matching-state',0));
   delete from app_private.match_relations where user_low in(${users}) or user_high in(${users});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(select id from app_private.intake_applications where user_id in(${users}));
   delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id in(${users}));
   delete from app_private.table_assignments where user_id in(${users});delete from app_private.dining_tables where slot_id=${slot};
   delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.refund_attempts where user_id in(${users});delete from app_private.payment_attempts where user_id in(${users});delete from app_private.intake_applications where user_id in(${users});
   delete from app_private.member_audit where actor_id in(${users},${op});delete from app_private.member_accounts where user_id in(${users});delete from auth.users where id in(${users});
   delete from app_private.intake_event_slots where id=${slot};delete from app_private.member_accounts where user_id=${op};delete from auth.users where id=${op};commit;`)
}
