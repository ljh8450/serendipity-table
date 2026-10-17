// Independent DB sessions, local synthetic users only; no external delivery.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const args=['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const db=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
const run=promisify(execFile),parallel=q=>run('docker',[...args,'-c',q],{encoding:'utf8'})
const prefix=readFileSync('supabase/tests/safety_permissions.sql','utf8').split('create function pg_temp.safety')[0]
for(const race of ['duplicate','matching','chat','payment','restrictionMatch','reviewRevision','revoke']){
 const label=`safety-race-${randomUUID()}`,next=label+'next',op=randomUUID(),actor=`md5('${label}1user')::uuid`,target=`md5('${label}2user')::uuid`,slots=`md5('${label}slot')::uuid,md5('${next}slot')::uuid`
 const apps=`select id from app_private.intake_applications where input->'slotIds' ?| array[md5('${label}slot')::uuid::text,md5('${next}slot')::uuid::text]`
 const assignments=`select id from app_private.table_assignments where application_id in(${apps})`
 const users=[label,next].flatMap(l=>Array.from({length:8},(_,i)=>`md5('${l}${i+1}user')::uuid`)).concat(`'${op}'::uuid`).join(',')
 try{
  db(prefix+`select pg_temp.person_fixture('${label}');select pg_temp.next_people('${next}','${label}',8);
   update app_private.intake_event_slots set matches_at=clock_timestamp()+interval '1 hour' where id=md5('${next}slot')::uuid;
   insert into auth.users(id) values('${op}');insert into app_private.member_accounts(user_id,role) values('${op}','operator');insert into app_private.safety_reviewers values('${op}');commit;`)
  const ids=db(`select id from app_private.table_assignments where application_id in(md5('${label}1app')::uuid,md5('${label}2app')::uuid) order by user_id=${actor} desc;`).split('\n')
  const key=randomUUID(),room=db(`select r.id from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=md5('${label}slot')::uuid;`)
  const report=`begin;set local statement_timeout='10s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;
   select app_private.safety_submit(jsonb_build_object('assignmentId','${ids[0]}','peerId','${ids[1]}','requestKey','${key}','kind','REPORT','category','OTHER','details','LOCAL SYNTHETIC RACE REPORT'));select pg_sleep(0.1);commit;`
  if(['payment','restrictionMatch','reviewRevision','revoke'].includes(race))db(report)
  const reportId=db(`select id from app_private.safety_reports where reporter_id=${actor};`)
  const review=(action,k=randomUUID())=>`begin;set local statement_timeout='10s';select set_config('app.actor_id','${op}',true);set local role app_member_api;
   do $$ begin begin perform app_private.operations_safety_review(jsonb_build_object('caseType','REPORT','caseId','${reportId}','requestKey','${k}','revision',0,'action','${action}','reason','local synthetic review race'));
   exception when raise_exception then if sqlerrm not in('SAFETY_CONFLICT','FORBIDDEN') then raise;end if;end;end $$;select pg_sleep(0.1);commit;`
  if(race==='payment')db(`begin;update app_private.intake_event_slots set closes_at=clock_timestamp()+interval '30 minutes' where id=md5('${next}slot')::uuid;delete from app_private.payment_attempts where application_id=md5('${next}2app')::uuid;update app_private.intake_applications set payment_status='PENDING',credit_payment_id=null where id=md5('${next}2app')::uuid;commit;`)
  if(['matching','restrictionMatch'].includes(race))db(`update app_private.intake_event_slots set matches_at=clock_timestamp()-interval '1 minute' where id=md5('${next}slot')::uuid;`)
  const first=['payment','restrictionMatch','reviewRevision','revoke'].includes(race)?review('RESTRICT'):report
  const second=race==='duplicate'?report:race==='matching'||race==='restrictionMatch'?`begin;select app_private.matching_tick();select pg_sleep(0.1);commit;`:
   race==='chat'?`begin;set local statement_timeout='10s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;do $$ begin begin perform app_private.chat_send(jsonb_build_object('roomId','${room}','requestKey','${randomUUID()}','body','LOCAL RACE MESSAGE'));exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;commit;`:
   race==='reviewRevision'?review('BAN'):race==='revoke'?`begin;select pg_advisory_xact_lock(hashtextextended('matching-state',0));delete from app_private.safety_reviewers where user_id='${op}';commit;`:
   `begin;set local statement_timeout='10s';select set_config('app.actor_id',${target}::text,true);set local role app_member_api;do $$ begin begin perform app_private.mock_payment(jsonb_build_object('applicationId',md5('${next}2app')::uuid,'requestKey','${randomUUID()}','outcome','success'));exception when raise_exception then if sqlerrm not in('PARTICIPATION_RESTRICTED','PAYMENT_CONFLICT') then raise;end if;end;end $$;commit;`
  await Promise.all([parallel(first),parallel(second)])
  if(db(`select count(*) from app_private.safety_reports where reporter_id=${actor};`)!=='1')throw Error('Duplicate/lost report')
  if(db(`select count(*) from app_private.table_assignments a join app_private.table_assignments b on a.table_id=b.table_id join app_private.dining_tables t on t.id=a.table_id join app_private.intake_event_slots s on s.id=t.slot_id where a.active and b.active and s.starts_at>clock_timestamp() and a.user_id=${actor} and b.user_id=${target};`)!=='0')throw Error('Unsafe future pair survived')
  if(db(`select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id join app_private.intake_event_slots s on s.id=t.slot_id where a.active and s.starts_at>clock_timestamp() and not app_private.safety_allowed(a.user_id);`)!=='0')throw Error('Restricted future assignment')
  if(race==='reviewRevision'&&db(`select revision from app_private.safety_accounts where user_id=${target};`)!=='1')throw Error('Stale review committed')
  if(race==='payment'&&Number(db(`select count(*) from app_private.payment_attempts where application_id=md5('${next}2app')::uuid;`))>1)throw Error('Duplicate payment')
  if(race==='chat')db(`begin;select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;do $$ begin begin perform app_private.chat_get(jsonb_build_object('roomId','${room}','before',null));raise exception 'access retained';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;rollback;`)
  if(race==='revoke')db(`begin;select set_config('app.actor_id','${op}',true);set local role app_member_api;do $$ begin begin perform app_private.operations_safety_detail(jsonb_build_object('caseType','REPORT','caseId','${reportId}'));raise exception 'capability retained';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;end $$;rollback;`)
 }finally{
  db(`begin;delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slots})) or aggregate_id in(${apps});delete from app_private.allocation_attempts where application_id in(${apps});
   delete from app_private.table_assignments where application_id in(${apps});delete from app_private.dining_tables where slot_id in(${slots});delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slots}));delete from app_private.match_jobs where slot_id in(${slots});
   delete from app_private.refund_attempts where user_id in(${users});delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id in(${slots});
   delete from app_private.member_audit where actor_id in(${users});delete from app_private.member_accounts where user_id in(${users});delete from auth.users where id in(${users});commit;`)
 }
}
console.log(JSON.stringify({duplicateReport:true,reportMatchingRace:true,reportChatRace:true,restrictionPaymentRace:true,restrictionMatchingRace:true,reviewRevisionRace:true,capabilityRevocationRace:true,localFixturesCleaned:true}))
