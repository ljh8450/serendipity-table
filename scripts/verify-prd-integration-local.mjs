// Continuous local event -> attendance -> feedback -> second-round matching.
// Profiles/payments are isolated SQL fixtures; UI submission is covered by Playwright.
// Every automatic stage below waits for real Cron, never calls a worker tick.
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
process.chdir(fileURLToPath(new URL('..', import.meta.url)))
const container='supabase_db_serendipity-table'
const db=q=>execFileSync('docker',['exec','-i',container,'psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
if(db('select current_database()')!=='postgres')throw Error('Unexpected local database')
const label=`prd-${randomUUID()}`,failed=`${label}-failed`,next=`${label}-next`,target=`${label}-target`,op=randomUUID()
const id=s=>`md5('${s}')::uuid`,slot=id(`${label}slot`),nextSlot=id(`${next}slot`),failedSlot=id(`${failed}slot`),targetSlot=id(`${target}slot`)
const users=Array.from({length:8},(_,i)=>id(`${label}${i+1}user`)),failureUsers=Array.from({length:3},(_,i)=>id(`${failed}${i+1}user`)),allUsers=[...users,...failureUsers]
const slots=[slot,nextSlot,failedSlot,targetSlot].join(',')
const prefix=readFileSync('supabase/tests/matching_permissions.sql','utf8').replace(/^\uFEFF/,'').split('do $$ declare count_n')[0]
const proof={localOnly:true,fixtureProfilesAndMockPayments:true,actualCron:true,stages:[],status:'running'}
const started=new Date().toISOString()
function check(ok,message){if(!ok)throw Error(message)}
function member(user,fn,payload){
 const body=payload===undefined?'':`'${JSON.stringify(payload).replaceAll("'","''")}'::jsonb`
 const rows=db(`begin;select set_config('app.actor_id',${user}::text,true);set local role app_member_api;select ${fn}(${body});commit;`).split('\n')
 return JSON.parse(rows.findLast(row=>row.startsWith('{')))
}
function mark(stage){proof.stages.push(stage);console.log('PASS PRD integration: '+stage)}
async function waitFor(stage,query,expected,timeout=150000){
 const end=Date.now()+timeout
 while(Date.now()<end){if(db(query)===String(expected)){mark(stage);return}await new Promise(r=>setTimeout(r,1500))}
 throw Error('Timed out: '+stage)
}
try{
 db(prefix+`select pg_temp.match_fixture('${label}',8);select pg_temp.match_fixture('${failed}',3);select pg_temp.match_fixture('${next}',0);select pg_temp.match_fixture('${target}',0);commit;`)
 db(`begin;update app_private.intake_event_slots set opens_at=now()-interval '1 day',closes_at=now()+interval '1 day',matches_at=now()+interval '2 days',starts_at=now()+interval '14 days' where id in(${nextSlot},${targetSlot});
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["10_20"],"allergies":"","avoidedFoods":""}' where user_id in(${allUsers});
 insert into auth.users(id) values('${op}');insert into app_private.member_accounts(user_id,role) values('${op}','operator');
 insert into app_private.member_consents(user_id,document_id) select u,d.id from unnest(array[${failureUsers}])u cross join app_private.consent_documents d where d.active on conflict do nothing;commit;`)
 for(let i=0;i<2;i++)member(`'${op}'::uuid`,'app_private.operations_venue_create',{requestKey:randomUUID(),slotId:db(`select ${slot}`),name:'LOCAL PRD INTEGRATION',address:'LOCAL FIXTURE ONLY',mapUrl:'https://example.test/map',reservationName:`${label}-${i}`,mealPriceKrw:15000,seats:6,rating:4.5,reviewCount:40,reviewUrl:'https://example.test/review',verifiedAt:new Date(Date.now()-60000).toISOString(),reservationValidUntil:new Date(Date.now()+15*86400000).toISOString(),safeAllergies:[],safeAvoidedFoods:[],verificationNote:'LOCAL FIXTURE ONLY',reservationConfirmed:true})
 await waitFor('eight paid people automatically confirmed in two valid tables',`select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and a.active`,8)
 check(db(`select count(*) from app_private.dining_tables t where t.slot_id=${slot} and (select count(*) from app_private.table_assignments a where a.table_id=t.id and a.active) not between 4 and 6`)==='0','Invalid table size')
 await waitFor('three-person group offered alternatives without weakening constraints',`select count(*) from app_private.intake_applications where user_id in(${failureUsers}) and matching_status='ALTERNATIVE_OFFERED'`,3)
 const beforePayments=db(`select count(*) from app_private.payment_attempts where user_id in(${failureUsers})`)
 const transfer=member(failureUsers[0],'app_private.match_resolve',{applicationId:db(`select ${id(`${failed}1app`)}`),requestKey:randomUUID(),action:'transfer',slotId:db(`select ${targetSlot}`)})
 check(!!transfer.newApplicationId,'Transfer did not create linked application')
 member(failureUsers[1],'app_private.match_resolve',{applicationId:db(`select ${id(`${failed}2app`)}`),requestKey:randomUUID(),action:'store'})
 member(failureUsers[2],'app_private.match_resolve',{applicationId:db(`select ${id(`${failed}3app`)}`),requestKey:randomUUID(),action:'refund',outcome:'success'})
 check(db(`select count(*) from app_private.payment_attempts where user_id in(${failureUsers})`)===beforePayments,'Transfer duplicated payment')
 mark('explicit transfer/store/mock refund preserve original payments')
 await waitFor('restaurants and real group rooms automatically allocated',`select (select count(*) from app_private.venue_allocations a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and a.active)+(select count(*) from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=${slot} and r.status='OPEN')`,4)
 // Shift only this fixture's event time, then let actual Cron publish within the real window.
 db(`begin;select pg_advisory_xact_lock(hashtextextended('content-tick',0));select pg_advisory_xact_lock(hashtextextended('matching-state',0));update app_private.intake_event_slots set starts_at=now()+interval '10 minutes' where id=${slot};update app_private.content_jobs j set scheduled_at=now()-interval '23 hours 50 minutes',due_at=now()-interval '23 hours 50 minutes' from app_private.dining_tables t where j.table_id=t.id and t.slot_id=${slot} and j.kind='D1';commit;`)
 await waitFor('D1 reminder automatically posted into both rooms',`select count(*) from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where t.slot_id=${slot} and j.kind='D1' and j.status='DONE'`,2)
 db(`begin;select pg_advisory_xact_lock(hashtextextended('content-tick',0));select pg_advisory_xact_lock(hashtextextended('matching-state',0));update app_private.intake_event_slots set starts_at=now()-interval '20 seconds' where id=${slot};update app_private.content_jobs j set scheduled_at=s.starts_at,due_at=s.starts_at from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id where j.table_id=t.id and t.slot_id=${slot} and j.kind='START';commit;`)
 await waitFor('START topics and games automatically posted into both rooms',`select count(*) from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where t.slot_id=${slot} and j.kind='START' and j.status='DONE'`,2)
 const assignments=JSON.parse(db(`select json_agg(json_build_object('id',a.id,'userId',a.user_id,'tableId',a.table_id)) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and a.active`))
 for(const a of assignments){const result=member(`'${a.userId}'::uuid`,'app_private.attendance_check_in',{assignmentId:a.id,requestKey:randomUUID()});check(result.attendances.some(x=>x.assignmentId===a.id&&x.status==='ATTENDED'),'Check-in missing')}
 mark('all eight participants checked in through authorized commands')
 db(`update app_private.intake_event_slots set starts_at=now()-interval '4 hours',closes_at=now()-interval '5 hours',matches_at=now()-interval '5 hours'+interval '1 minute' where id=${slot};`)
 await waitFor('feedback requests automatically generated after event end',`select count(*) from app_private.feedback_jobs j join app_private.table_assignments a on a.id=j.assignment_id join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and j.kind='REQUEST' and j.status='DONE'`,8)
 for(const a of assignments)member(`'${a.userId}'::uuid`,'app_private.feedback_submit',{assignmentId:a.id,requestKey:randomUUID(),ratings:{atmosphere:5,conversation:4,venue:5,revisit:true,recommend:true}})
 const first=assignments[0],peer=assignments.find(a=>a.tableId===first.tableId&&a.id!==first.id)
 const prefs=member(`'${first.userId}'::uuid`,'app_private.preferences_get')
 const source=prefs.events.find(e=>e.assignmentId===first.id),selected=source.peers.find(p=>p.peerId===peer.id)
 check(!!selected,'Joint attendance peer unavailable')
 member(`'${first.userId}'::uuid`,'app_private.preferences_save',{assignmentId:first.id,peerId:selected.peerId,requestKey:randomUUID(),value:'AVOID',revision:selected.revision})
 mark('ratings and private peer choice saved after the same event')
 db(`begin;insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
 select md5('${next}'||a.user_id::text)::uuid,a.user_id,gen_random_uuid(),jsonb_set(a.input,'{slotIds}',jsonb_build_array(${nextSlot})),'{}',a.onboarding_snapshot,a.schema_version,a.consent_snapshot,a.product_snapshot,'PAID' from app_private.intake_applications a where a.user_id in(${users});
 insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) select user_id,id,gen_random_uuid(),'success',9900 from app_private.intake_applications where input->'slotIds' ? ${nextSlot}::text;
 update app_private.intake_event_slots set closes_at=now()-interval '2 minutes',matches_at=now()-interval '1 minute' where id=${nextSlot};commit;`)
 await waitFor('second round automatically matches the same eight people',`select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${nextSlot} and a.active`,8)
 check(db(`select count(*) from app_private.table_assignments a join app_private.table_assignments b on b.table_id=a.table_id and b.active join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${nextSlot} and a.active and a.user_id='${first.userId}' and b.user_id='${peer.userId}'`)==='0','Private avoid ignored in next round')
 check(db(`select count(*) from app_private.operations_interventions where subject_user_id in(${allUsers})`)==='0','Normal workflow required an operator intervention')
 check(Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where d.status='succeeded' and d.start_time>='${started}'::timestamptz and j.jobname in('serendipity-matching-tick','serendipity-content-tick')`))>0,'Missing actual Cron evidence')
 mark('private avoid applied next round; normal path needed no operator action')
 proof.status='passed'
}catch(error){proof.status='failed';proof.error=error.message;throw error}
finally{
 db(`begin;select pg_advisory_xact_lock(hashtextextended('matching-state',0));
 delete from app_private.person_preferences where user_id in(${allUsers}) or target_user_id in(${allUsers});delete from app_private.preference_commands where user_id in(${allUsers});
 delete from app_private.attendance_actions where assignment_id in(select id from app_private.table_assignments where user_id in(${allUsers}));delete from app_private.attendance_records where assignment_id in(select id from app_private.table_assignments where user_id in(${allUsers}));
 delete from app_private.feedback_jobs where assignment_id in(select id from app_private.table_assignments where user_id in(${allUsers}));delete from app_private.event_feedback where user_id in(${allUsers});
 delete from app_private.match_relations where user_low in(${allUsers}) or user_high in(${allUsers});delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slots})) or aggregate_id in(select id from app_private.intake_applications where user_id in(${allUsers}));
 delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id in(${allUsers}));delete from app_private.table_assignments where user_id in(${allUsers});delete from app_private.dining_tables where slot_id in(${slots});
 delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slots}));delete from app_private.match_jobs where slot_id in(${slots});
 delete from app_private.refund_attempts where user_id in(${allUsers});delete from app_private.payment_attempts where user_id in(${allUsers});delete from app_private.intake_applications where user_id in(${allUsers});
 delete from app_private.venue_inventory where slot_id in(${slots});delete from app_private.member_audit where actor_id in(${allUsers},'${op}'::uuid);delete from auth.users where id in(${allUsers},'${op}'::uuid);delete from app_private.intake_event_slots where id in(${slots});commit;`)
 proof.finishedAt=new Date().toISOString();writeFileSync('.local/prd-integration-proof.json',JSON.stringify(proof,null,2))
}
