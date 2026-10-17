// Fixed local container, synthetic users only; no browser or external delivery.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const args = ['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const db = q => execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
const run = promisify(execFile)
const parallel = q => run('docker',[...args,'-c',q],{encoding:'utf8'})
const prefix = readFileSync('supabase/tests/matching_permissions.sql','utf8').split('do $$ declare count_n')[0]
for (const race of ['reminder','attendance','revocation']) {
 const label = `feedback-race-${randomUUID()}`,slot = `md5('${label}slot')::uuid`,app = `md5('${label}1app')::uuid`,actor = `md5('${label}1user')::uuid`
 const apps = `select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text`
 const assignments = `select id from app_private.table_assignments where application_id in(${apps})`
 const others = [1,2,3,4].map(i=>`md5('${label}${i}user')::uuid`).join(',')
 let target
 try {
  db(prefix+`select pg_temp.match_fixture('${label}',4);select app_private.matching_tick();
   update app_private.intake_applications set attendance_status='ATTENDED' where id=${app};
   update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=${slot};
   select app_private.feedback_tick();select app_private.feedback_tick();
   update app_private.feedback_jobs set due_at=clock_timestamp() where assignment_id in(${assignments}) and kind='REMINDER';commit;`)
  target = db(`select id from app_private.table_assignments where application_id=${app};`)
  if (!/^[0-9a-f-]{36}$/.test(target)) throw new Error('Missing local assignment')
  if (race==='reminder') {
   await Promise.all([parallel("begin;select pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));select pg_advisory_xact_lock(hashtextextended('attendance-state',0));select pg_sleep(0.4);commit;"),parallel('begin;select pg_sleep(0.1);select app_private.attendance_tick();commit;')])
   if (db(`select count(*) from app_private.attendance_records where assignment_id in(${assignments}) and closed_at is not null;`)!=='4') throw new Error('Attendance close skipped under contention')
  }
  const command = `begin;set local statement_timeout='8s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;
   do $$ begin begin perform app_private.feedback_submit(jsonb_build_object('assignmentId','${target}','requestKey','${randomUUID()}','ratings','{"atmosphere":4,"conversation":5,"venue":3,"revisit":true,"recommend":false}'::jsonb));
   exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;select pg_sleep(0.15);commit;`
  const other = race === 'reminder' ? 'begin;select app_private.feedback_tick();select pg_sleep(0.15);commit;'
   : `begin;select ${race === 'revocation' ? 'pg_advisory_xact_lock' : 'pg_advisory_xact_lock_shared'}(hashtextextended('matching-state',0));select pg_advisory_xact_lock(hashtextextended('attendance-state',0));
    ${race === 'attendance' ? `update app_private.intake_applications set attendance_status='NO_SHOW' where id=${app};` : `update app_private.table_assignments set active=false where id='${target}';`}
    select pg_sleep(0.15);commit;`
  await Promise.all([parallel(command),parallel(other)])
  const count = Number(db(`select count(*) from app_private.event_feedback where assignment_id='${target}';`))
  if (count>1 || (race==='reminder' && count!==1)) throw new Error('Lost/duplicate feedback')
  if (Number(db(`select count(*) from app_private.member_notifications where application_id=${app} and kind='FEEDBACK_REMINDER';`))>1) throw new Error('Duplicate reminder')
  const visible = db(`begin;select set_config('app.actor_id',${actor}::text,true);select count(*) from app_private.member_notifications n where n.kind like 'FEEDBACK_%' and app_private.notification_visible(n,${actor});rollback;`).split('\n').filter(s=>s==='0').length
  if (!visible) throw new Error('Stale reminder visible')
 } finally {
  db(`begin;delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(${apps});
   delete from app_private.allocation_attempts where application_id in(${apps});delete from app_private.table_assignments where application_id in(${apps});
   delete from app_private.dining_tables where slot_id=${slot};delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id=${slot};
   delete from app_private.member_audit where actor_id in(${others});delete from app_private.member_accounts where user_id in(${others});delete from auth.users where id in(${others});commit;`)
 }
}
console.log(JSON.stringify({attendanceCloseWaits:true,submitReminderRace:true,attendanceCorrectionRace:true,assignmentRevocationRace:true,noExternalDelivery:true,localFixturesCleaned:true}))
