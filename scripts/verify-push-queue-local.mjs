import {execFileSync,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
process.chdir(fileURLToPath(new URL('..',import.meta.url)));
const args=['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'];
const db=q=>execFileSync('docker',args,{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const run=promisify(execFile),usr=randomUUID(),endpoint='https://fcm.googleapis.com/send/LOCAL-QUEUE-'+randomUUID();
let active;
try {
 if(db("select count(*) from app_private.push_jobs where status in('PENDING','RUNNING');")!=='0')throw Error('Refusing unrelated queued work');
 active=db("select active from cron.job where jobname='serendipity-push-dispatch';");
 if(!['t','f'].includes(active))throw Error('Missing project push Cron');
 db("select cron.alter_job((select jobid from cron.job where jobname='serendipity-push-dispatch'),active:=false);");
 await new Promise(r=>setTimeout(r,2000));
 db(`begin;insert into auth.users(id) values('${usr}');insert into app_private.member_accounts(user_id) values('${usr}');insert into app_private.push_subscriptions(user_id,endpoint,p256dh,auth) values('${usr}','${endpoint}','B'||repeat('A',86),repeat('A',22));insert into app_private.member_notifications(user_id,event_key,kind) values('${usr}','queue-proof','PUSH_TEST');commit;`);
 const values=await Promise.all([1,2].map(()=>run('docker',[...args,'-c',"begin;set local role app_push_worker;select app_private.push_claim();select pg_sleep(0.2);commit;"],{encoding:'utf8'})));
 const jobs=values.map(v=>v.stdout.split('\n').find(s=>s.startsWith('{'))).filter(Boolean).map(s=>JSON.parse(s));
 if(jobs.length!==1)throw Error('Concurrent claim duplicated or lost job');
 const j=jobs[0];
 db(`update app_private.push_jobs set lease_until=clock_timestamp()-interval '1 second' where id='${j.id}';`);
 const reclaimed=JSON.parse(db('select app_private.push_claim();'));
 if(reclaimed.token===j.token||reclaimed.id!==j.id)throw Error('Lease reclaim failed');
 if(db(`select app_private.push_finish('${j.id}','${j.token}',201);`)!=='f')throw Error('Old lease accepted');
 await Promise.all([
  run('docker',[...args,'-c',`begin;select set_config('app.actor_id','${usr}',true);set local role app_member_api;select app_private.push_unsubscribe(jsonb_build_object('endpoint','${endpoint}'));select pg_sleep(0.2);commit;`],{encoding:'utf8'}),
  run('docker',[...args,'-c',`begin;set local role app_push_worker;select app_private.push_finish('${j.id}','${reclaimed.token}',410);commit;`],{encoding:'utf8'})
 ]);
 if(db(`select status from app_private.push_jobs where id='${j.id}';`)!=='CANCELED')throw Error('Unsubscribe/finish race failed');
 console.log(JSON.stringify({parallelClaimUnique:true,leaseReclaim:true,oldLeaseRejected:true,unsubscribeFinishRace:true,noExternalSend:true,localOnly:true}));
}finally{
 db(`begin;delete from app_private.member_audit where actor_id='${usr}';delete from app_private.member_accounts where user_id='${usr}';delete from auth.users where id='${usr}';commit;`);
 if(['t','f'].includes(active))db(`select cron.alter_job((select jobid from cron.job where jobname='serendipity-push-dispatch'),active:=${active==='t'?'true':'false'});`);
}
