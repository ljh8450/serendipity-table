// Local-only publication/matching race. No remote connection or credentials.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const args = ['exec', '-i', 'supabase_db_serendipity-table', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At']
const db = q => execFileSync('docker', args, { input: q, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim()
const run = promisify(execFile)
const parallel = q => run('docker', [...args, '-c', q], { encoding: 'utf8' })
const label = `policy-race-${randomUUID()}`
const actor = `md5('${label}operator')::uuid`, slot = `md5('${label}slot')::uuid`
const users = Array.from({ length: 4 }, (_, i) => `md5('${label}${i + 1}user')::uuid`).join(',')
const prefix = readFileSync('supabase/tests/matching_permissions.sql', 'utf8').split('do $$ declare count_n')[0]
const old = JSON.parse(db('select to_jsonb(p) from app_private.matching_policy p where active;'))
const command = payload => `begin; select set_config('app.actor_id',${actor}::text,true); set local role app_member_api; select app_private.operations_policy_save('${JSON.stringify(payload)}'::jsonb);commit;`
let seeded = false
try {
 db(prefix + `select pg_temp.match_fixture('${label}',4);insert into auth.users(id) values(${actor});insert into app_private.member_accounts(user_id,role) values(${actor},'operator');commit;`); seeded = true
 await Promise.all([
  parallel(command({ expectedVersion: old.version, minimumScore: old.minimum_score === 35 ? 36 : 35, weights: old.weights })),
  parallel('begin;select app_private.matching_tick();select pg_sleep(0.2);commit;'),
 ])
 const result = JSON.parse(db(`select jsonb_build_object('assigned',(select count(*) from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id where t.slot_id=${slot} and ta.active),'policySnapshotsValid',not exists(select 1 from app_private.match_runs r join app_private.match_jobs j on j.id=r.job_id where j.slot_id=${slot} and (r.policy_version is null or not r.policy_snapshot ?& array['version','weights','minimum_score'])));`))
 if (result.assigned !== 4 || !result.policySnapshotsValid) throw Error('Publication/matching race failed')
 console.log(JSON.stringify({ publicationMatchingRace: true, uniqueAssignments: true, policySnapshotsValid: true, localOnly: true }))
} finally {
 if (seeded) {
  const current = db('select version from app_private.matching_policy where active;')
  db(command({ expectedVersion: current, minimumScore: old.minimum_score, weights: old.weights }))
  db(`begin;select pg_advisory_xact_lock(hashtextextended('matching-state',0));
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(select id from app_private.intake_applications where user_id in(${users}));
   delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id in(${users}));
   delete from app_private.table_assignments where user_id in(${users});delete from app_private.dining_tables where slot_id=${slot};
   delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.payment_attempts where user_id in(${users});delete from app_private.intake_applications where user_id in(${users});delete from app_private.intake_event_slots where id=${slot};
   delete from app_private.member_audit where actor_id in(${users},${actor});delete from app_private.member_accounts where user_id in(${users},${actor});delete from auth.users where id in(${users},${actor});commit;`)
 }
}
