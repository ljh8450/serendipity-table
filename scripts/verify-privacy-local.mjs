// Local synthetic fixtures only. No live user records or outbound Auth calls.
import { execFileSync,execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const args=['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const db=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim(),run=promisify(execFile)
const parallel=q=>run('docker',[...args,'-c',q],{encoding:'utf8'})
const prefix=readFileSync('supabase/tests/matching_permissions.sql','utf8').split('do $$ declare count_n')[0]
const cronNames="'serendipity-matching-tick','serendipity-privacy-auth'"
if(db("select count(*) from app_private.privacy_auth_jobs where status in('PENDING','RUNNING')")!=='0')throw Error('Refusing unrelated privacy work')
const crons=JSON.parse(db(`select coalesce(json_agg(json_build_object('id',jobid,'active',active)),'[]') from cron.job where jobname in(${cronNames})`))
db(`select cron.alter_job(jobid,active=>false) from cron.job where jobname in(${cronNames})`)
try{
 for(const race of ['duplicate','profile','matching','payment']){
  const label=`privacy-race-${randomUUID()}`,actor=`md5('${label}1user')::uuid`,slot=`md5('${label}slot')::uuid`,key=randomUUID()
  const apps=`select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text`,assignments=`select id from app_private.table_assignments where application_id in(${apps})`,users=Array.from({length:4},(_,i)=>`md5('${label}${i+1}user')::uuid`).join(',')
  const withdraw=`begin;set local statement_timeout='10s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;select app_private.privacy_withdraw(jsonb_build_object('requestKey','${key}','confirmation','탈퇴'));commit;`
  try{
   db(prefix+`select pg_temp.match_fixture('${label}',4);${['duplicate','profile'].includes(race)?'select app_private.matching_tick();':''}commit;`)
   if(race==='payment')db(`begin;update app_private.intake_event_slots set closes_at=clock_timestamp()+interval '30 minutes' where id=${slot};delete from app_private.payment_attempts where user_id=${actor};update app_private.intake_applications set payment_status='PENDING',credit_payment_id=null where user_id=${actor};commit;`)
   const profile={name:'LOCAL RACE',contact:'test-contact',birthYear:1995,gender:'test',occupation:'test',mbti:['INTJ'],interests:['food'],traits:[],preferredTraits:[],mealBudgetMin:10000,mealBudgetMax:30000,avoidedFoods:[],allergies:[]}
   const second=race==='duplicate'?withdraw:race==='matching'?`begin;set local statement_timeout='10s';select app_private.matching_tick();commit;`:race==='profile'?`begin;set local statement_timeout='10s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;select app_private.member_get();select pg_sleep(0.5);select app_private.member_profile_save('${JSON.stringify(profile)}'::jsonb);commit;`:`begin;set local statement_timeout='10s';select set_config('app.actor_id',${actor}::text,true);set local role app_member_api;select app_private.mock_payment(jsonb_build_object('applicationId',md5('${label}1app')::uuid,'requestKey','${randomUUID()}','outcome','success'));commit;`
   let results
   if(race==='profile'){const pending=parallel(second);pending.catch(()=>{});await new Promise(resolve=>setTimeout(resolve,150));results=await Promise.allSettled([parallel(withdraw),pending])}
   else results=await Promise.allSettled([parallel(withdraw),parallel(second)])
   if(results[0].status!=='fulfilled')throw Error('Withdrawal failed under contention')
   if(results[1].status==='rejected'&&!['profile','payment'].includes(race))throw Error('Unexpected concurrent command failure')
   if(results[1].status==='rejected'&&!/FORBIDDEN|PARTICIPATION_RESTRICTED/.test(String(results[1].reason.stderr)))throw Error('Unexpected privacy race error: '+String(results[1].reason.stderr).split('\n')[0])
   if(db(`select count(*) from app_private.member_withdrawals where user_id=${actor}`)!=='1')throw Error('Duplicate withdrawal')
   if(db(`select count(*) from app_private.member_profiles where user_id=${actor}`)!=='0')throw Error('Personal write survived withdrawal')
   if(db(`select count(*) from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id where ta.user_id=${actor} and ta.active and s.starts_at>clock_timestamp()`)!=='0')throw Error('Withdrawn future assignment')
   if(db(`select count(*) from app_private.dining_tables t where t.slot_id=${slot} and t.status='CONFIRMED' and (select count(*) from app_private.table_assignments where table_id=t.id and active) not between 4 and 6`)!=='0')throw Error('Invalid remaining table')
   console.log(`PASS privacy ${race} concurrency`)
  }finally{
   db(`begin;select pg_advisory_xact_lock(hashtextextended('matching-state',0));delete from app_private.privacy_auth_jobs where user_id in(${users});delete from app_private.privacy_holds where user_id in(${users});delete from app_private.member_withdrawals where user_id in(${users});delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(${apps});delete from app_private.allocation_attempts where application_id in(${apps});delete from app_private.table_assignments where application_id in(${apps});delete from app_private.dining_tables where slot_id=${slot};delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};delete from app_private.refund_attempts where user_id in(${users});delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id=${slot};delete from app_private.member_audit where actor_id in(${users});delete from auth.users where id in(${users});commit;`)
  }
 }
}finally{
 for(const c of crons)db(`select cron.alter_job(${Number(c.id)},active=>${c.active?'true':'false'})`)
}
