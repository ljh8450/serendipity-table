// Fixed local project only; synthetic identities and no external delivery.
import { execFileSync, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { randomUUID } from 'node:crypto'
const args=['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At']
const db=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
const run=promisify(execFile),actor=randomUUID(),other=randomUUID(),slot=randomUUID(),key=randomUUID()
const call=(user,p)=>`begin;set local role app_member_api;select set_config('app.actor_id','${user}',true);select app_private.operations_work('${JSON.stringify(p)}'::jsonb);commit;`
const parallel=q=>run('docker',[...args,'-c',q],{encoding:'utf8'})
try{
 db(`begin;insert into auth.users(id) values('${actor}'),('${other}');insert into app_private.member_accounts(user_id,role) values('${actor}','operator'),('${other}','operator');insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,region_code,region_label) values('${slot}',now()+interval '2 days',now(),now()+interval '1 day','hongdae','LOCAL OPERATIONS RACE');commit;`)
 await Promise.all([parallel(call(actor,{action:'start',slotId:slot,requestKey:key})),parallel(call(actor,{action:'start',slotId:slot,requestKey:key}))])
 if(db(`select count(*) from app_private.operations_work_sessions where actor_id='${actor}'`)!=='1')throw Error('Duplicate work start')
 const session=db(`select id from app_private.operations_work_sessions where actor_id='${actor}'`)
 const forbidden=await Promise.allSettled([parallel(call(other,{action:'stop',sessionId:session,requestKey:randomUUID()}))])
 if(forbidden[0].status!=='rejected'||!String(forbidden[0].reason.stderr).includes('FORBIDDEN'))throw Error('Cross-actor session stop')
 const stop=randomUUID()
 await Promise.all([parallel(call(actor,{action:'stop',sessionId:session,requestKey:stop})),parallel(call(actor,{action:'stop',sessionId:session,requestKey:stop}))])
 if(db(`select count(*) from app_private.operations_work_sessions where actor_id='${actor}' and ended_at is not null`)!=='1')throw Error('Duplicate work stop')
 const different=await Promise.allSettled([parallel(call(actor,{action:'start',slotId:slot,requestKey:randomUUID()})),parallel(call(actor,{action:'start',slotId:slot,requestKey:randomUUID()}))])
 if(different.filter(r=>r.status==='fulfilled').length!==1||different.filter(r=>r.status==='rejected'&&String(r.reason.stderr).includes('WORK_CONFLICT')).length!==1)throw Error('Concurrent open sessions allowed')
 console.log('PASS operations: same-key start/stop, cross-actor denial and competing starts')
}finally{
 db(`begin;delete from app_private.operations_work_sessions where actor_id in('${actor}','${other}');delete from app_private.intake_event_slots where id='${slot}';delete from auth.users where id in('${actor}','${other}');commit;`)
}
