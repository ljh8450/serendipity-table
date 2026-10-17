// Local synthetic fixtures only. Independent PostgreSQL sessions exercise the finalization fence.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const args=['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const db=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
const run=promisify(execFile), parallel=q=>run('docker',[...args,'-c',q],{encoding:'utf8'})
const prefix=readFileSync('supabase/tests/preferences_permissions.sql','utf8').split('do $$ declare s uuid')[0]
for(const race of ['duplicate','revision','matching','attendance']){
 const label=`person-race-${randomUUID()}`, next=label+'next',actor=`md5('${label}1user')::uuid`,target=`md5('${label}2user')::uuid`
 const slots=`md5('${label}slot')::uuid,md5('${next}slot')::uuid`
 const apps=`select id from app_private.intake_applications where input->'slotIds' ?| array[md5('${label}slot')::uuid::text,md5('${next}slot')::uuid::text]`
 const assignments=`select id from app_private.table_assignments where application_id in(${apps})`
 const users=[label,next].flatMap(l=>Array.from({length:8},(_,i)=>`md5('${l}${i+1}user')::uuid`)).join(',')
 try{
  db(prefix+`select pg_temp.person_fixture('${label}');select pg_temp.next_people('${next}','${label}',8);commit;`)
  const ids=db(`select id from app_private.table_assignments where application_id in(md5('${label}1app')::uuid,md5('${label}2app')::uuid) order by user_id=${actor} desc;`).split('\n')
  if(ids.length!==2)throw Error('Source pair missing')
  const key=randomUUID()
  const command=(k,value='AVOID')=>`begin;set local statement_timeout='10s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;
   do $$ begin begin perform app_private.preferences_save(jsonb_build_object('assignmentId','${ids[0]}','peerId','${ids[1]}','value','${value}','revision',0,'requestKey','${k}'));
   exception when raise_exception then if sqlerrm not in('PREFERENCE_CONFLICT','FORBIDDEN') then raise;end if;end;end $$;select pg_sleep(0.1);commit;`
  const other=race==='duplicate'?command(key):race==='revision'?command(randomUUID(),'LIKE'):race==='matching'?`begin;set local statement_timeout='10s';select app_private.matching_tick();select pg_sleep(0.1);commit;`:
   `begin;set local statement_timeout='10s';select pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));select pg_advisory_xact_lock(hashtextextended('attendance-state',0));update app_private.intake_applications set attendance_status='NO_SHOW' where id=md5('${label}2app')::uuid;select pg_sleep(0.1);commit;`
  await Promise.all([parallel(command(key)),parallel(other)])
  const count=Number(db(`select count(*) from app_private.preference_commands where user_id=${actor};`))
  if(race!=='attendance'&&count!==1)throw Error('Duplicate/lost command')
  if(Number(db(`select coalesce(max(revision),0) from app_private.person_preferences where user_id=${actor};`))>1)throw Error('Stale revision committed')
  if(race==='matching'){
   db('select app_private.matching_tick();')
   if(db(`select count(*) from app_private.table_assignments a join app_private.table_assignments b on b.table_id=a.table_id join app_private.dining_tables t on t.id=a.table_id where a.active and b.active and t.status='CONFIRMED' and t.slot_id=md5('${next}slot')::uuid and a.user_id=${actor} and b.user_id=${target};`)!=='0')throw Error('Avoided future pair confirmed')
  }
  if(race==='attendance'&&db(`select app_private.match_pair_blocked(${actor},${target}) or app_private.match_pair_met(${actor},${target});`)!=='f')throw Error('Corrected attendance retained evidence')
 }finally{
  db(`begin;delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slots})) or aggregate_id in(${apps});
   delete from app_private.allocation_attempts where application_id in(${apps});delete from app_private.table_assignments where application_id in(${apps});delete from app_private.dining_tables where slot_id in(${slots});
   delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slots}));delete from app_private.match_jobs where slot_id in(${slots});
   delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id in(${slots});
   delete from app_private.member_audit where actor_id in(${users});delete from app_private.member_accounts where user_id in(${users});delete from auth.users where id in(${users});commit;`)
 }
}
console.log(JSON.stringify({duplicateRace:true,revisionRace:true,matchingRace:true,attendanceCorrectionRace:true,localFixturesCleaned:true}))
