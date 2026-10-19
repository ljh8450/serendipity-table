import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db=(q:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('mobile report separates immediately; privileged review restricts participation, preserves refund and next Cron exclusion',async({page,request})=>{
 test.setTimeout(220000)
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const reporter=data.users[3],target=data.users[1],operator=data.users[2],label=`e2e-safety-${randomUUID()}`,next=label+'next'
 const api=`${data.apiUrl}/functions/v1/member`,slot=`md5('${label}slot')::uuid`,slots=`${slot},md5('${next}slot')::uuid`
 const apps=`select id from app_private.intake_applications where input->'slotIds' ?| array[${slot}::text,md5('${next}slot')::uuid::text]`
 const assignments=`select id from app_private.table_assignments where application_id in(${apps})`
 const fakeUsers=[label,next].flatMap(l=>Array.from({length:8},(_,i)=>`md5('${l}${i+1}user')::uuid`)).join(',')
 const prefix=readFileSync(path.resolve('../supabase/tests/safety_permissions.sql'),'utf8').split('create function pg_temp.safety')[0]
 const secret='LOCAL 신고 원문 <script>window.safetyLeak=true</script> 안전 검토 전용'
 const keys:string[]=[]
 db(prefix+`select pg_temp.match_fixture('${label}',4);
  insert into app_private.member_accounts(user_id) values('${reporter.id}'),('${target.id}') on conflict do nothing;
  update app_private.intake_applications set user_id=case when id=md5('${label}1app')::uuid then '${reporter.id}'::uuid else '${target.id}'::uuid end where id in(md5('${label}1app')::uuid,md5('${label}2app')::uuid);
  update app_private.payment_attempts p set user_id=a.user_id from app_private.intake_applications a where p.application_id=a.id and a.input->'slotIds' ? ${slot}::text;
  select app_private.matching_tick();select app_private.chat_tick();commit;`)
 const original=db(`select jsonb_build_object('exists',exists(select 1 from app_private.safety_accounts where user_id=a.user_id),'state',coalesce((select state from app_private.safety_accounts where user_id=a.user_id),'ACTIVE'),'revision',coalesce((select revision from app_private.safety_accounts where user_id=a.user_id),0)) from app_private.member_accounts a where user_id='${target.id}';`)
 const originalState=JSON.parse(original)
 const login=async(u:{email:string;password:string})=>{await page.goto('/#account');const out=page.getByRole('button',{name:'로그아웃',exact:true});if(await out.count())await out.click();await page.getByLabel('이메일',{exact:true}).fill(u.email);await page.getByLabel('비밀번호',{exact:true}).fill(u.password);await page.getByRole('button',{name:'로그인',exact:true}).click()}
 const auth=async(u:{email:string;password:string})=>{const r=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:u.email,password:u.password}});return(await r.json()).access_token}
 try{
  const ownId=db(`select id from app_private.table_assignments where application_id=md5('${label}1app')::uuid;`),peerId=db(`select id from app_private.table_assignments where application_id=md5('${label}2app')::uuid;`)
  const room=db(`select r.id from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=${slot};`)
  await login(reporter)
  const panel=page.getByRole('region',{name:'신고·차단과 나의 안전 상태',exact:true})
  await panel.getByLabel('함께 배정된 식탁·상대',{exact:true}).selectOption(peerId)
  await expect(panel.getByText(/^선택한 식탁·상대:.*참가자/)).toBeVisible()
  await panel.getByLabel('신고 내용 (10~2000자)',{exact:true}).fill('          ')
  await panel.getByLabel('선택한 상대와 접수 결과를 확인했어요.',{exact:true}).check()
  await panel.getByRole('button',{name:'안전 접수 제출',exact:true}).click()
  await expect(panel.getByRole('alert')).toContainText('신고 내용은 앞뒤 공백을 제외하고 10~2000자')
  await panel.screenshot({path:'../.local/safety-validation-mobile.png'})
  await panel.getByLabel('신고 내용 (10~2000자)',{exact:true}).fill(secret)
  await panel.getByLabel('선택한 상대와 접수 결과를 확인했어요.',{exact:true}).check()
  await panel.screenshot({path:'../.local/safety-report-mobile.png'})
  let lost=false
  await page.route('**/member/safety/submit',async route=>{keys.push(route.request().postDataJSON().requestKey);if(!lost){lost=true;const rs=await Promise.all([route.fetch(),route.fetch()]);for(const r of rs)expect(r.status()).toBe(200);await route.abort('failed')}else await route.continue()})
  await panel.getByRole('button',{name:'안전 접수 제출',exact:true}).click();await expect(panel.getByRole('alert')).toBeVisible();await expect(panel.getByLabel('신고 내용 (10~2000자)',{exact:true})).toHaveValue(secret)
  await panel.getByRole('button',{name:'안전 접수 제출',exact:true}).click();await expect(panel.getByRole('status')).toHaveText('신고를 접수하고 두 분을 매칭에서 분리했어요. 운영자가 내용을 검토해요.')
  expect(keys).toHaveLength(2);expect(keys[0]).toBe(keys[1])
  expect(db(`select count(*) from app_private.safety_reports where assignment_id='${ownId}';`)).toBe('1')
  expect(db(`select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where t.slot_id=${slot} and a.active;`)).toBe('0')
  const reportId=db(`select id from app_private.safety_reports where assignment_id='${ownId}';`)
  const reporterToken=await auth(reporter),targetToken=await auth(target),opToken=await auth(operator)
  const headers=(token:string)=>({authorization:`Bearer ${token}`})
  const targetRead=await request.get(api+'/safety',{headers:headers(targetToken)})
  expect(targetRead.status()).toBe(200);const targetDto=await targetRead.json();expect(targetDto.reports).toHaveLength(0);expect(targetDto.contexts.flatMap((c:{peers:{separated:boolean}[]})=>c.peers).some((p:{separated:boolean})=>p.separated)).toBe(false);expect(JSON.stringify(targetDto)).not.toMatch(/LOCAL 신고 원문|details|reporter_id|target_id|birthYear/)
  expect((await request.get(api+`/chat/${room}`,{headers:headers(reporterToken)})).status()).toBe(403)
  expect((await request.get(api+'/operations/safety',{headers:headers(reporterToken)})).status()).toBe(403)
  const detailBody={caseType:'REPORT',caseId:reportId}
  const summary=await request.get(api+'/operations/safety',{headers:headers(opToken)})
  expect(JSON.stringify(await summary.json())).not.toMatch(/LOCAL 신고 원문|details|reporter_id|target_id/)
  expect((await request.post(api+'/operations/safety/detail',{headers:headers(opToken),data:detailBody})).status()).toBe(403)
  expect((await request.get(api+'/safety?now=2099-01-01',{headers:headers(reporterToken)})).status()).toBe(422)
  expect((await request.post(api+'/safety/submit',{headers:headers(reporterToken),data:{assignmentId:ownId,peerId,requestKey:randomUUID(),kind:'BLOCK',userId:target.id}})).status()).toBe(422)
  const alienToken=await auth(data.users[0])
  expect((await request.post(api+'/safety/submit',{headers:headers(alienToken),data:{assignmentId:ownId,peerId,requestKey:randomUUID(),kind:'BLOCK'}})).status()).toBe(403)
  await login(operator);await page.getByRole('link',{name:'운영 관리',exact:true}).click();await page.getByRole('button',{name:'안전·개인정보',exact:true}).click()
  const monitor=page.getByRole('region',{name:'안전 신고·참가 제한 검토',exact:true})
  await expect(monitor.getByText('사건 요약만 볼 수 있어요. 원문 조회와 조치는 별도의 안전 검토 권한이 필요해요.',{exact:true})).toBeVisible()
  db(`insert into app_private.safety_reviewers(user_id) values('${operator.id}');`)
  await monitor.getByRole('button',{name:'안전 검토 새로고침',exact:true}).click()
  await monitor.getByRole('button',{name:`사건 상세 확인 ${reportId.slice(0,8)}`,exact:true}).click()
  await expect(monitor.getByText(secret,{exact:true})).toBeVisible();expect(await page.evaluate(()=>('safetyLeak' in window))).toBe(false)
  const actionForm=monitor.getByRole('form',{name:'안전 사건 조치',exact:true})
  await actionForm.getByLabel('조치 선택',{exact:true}).selectOption('WARN');await actionForm.getByLabel('조치 사유 (5~500자, 내부 기록)',{exact:true}).fill('     ')
  await actionForm.getByRole('checkbox').check();await actionForm.getByRole('button',{name:'안전 조치 저장',exact:true}).click()
  await expect(monitor.getByRole('alert')).toContainText('사유는 앞뒤 공백을 제외하고 5~500자')
  await actionForm.getByLabel('조치 사유 (5~500자, 내부 기록)',{exact:true}).fill('LOCAL 검토 후 경고 기록')
  await actionForm.getByRole('checkbox').check();await actionForm.getByRole('button',{name:'안전 조치 저장',exact:true}).click()
  await expect(monitor.getByText('참가 상태: 경고 · 검토 완료',{exact:true})).toBeVisible()
  await actionForm.getByLabel('조치 선택',{exact:true}).selectOption('RESTRICT');await actionForm.getByLabel('조치 사유 (5~500자, 내부 기록)',{exact:true}).fill('LOCAL 검토 후 참가 제한')
  await actionForm.getByRole('checkbox').check();await actionForm.getByRole('button',{name:'안전 조치 저장',exact:true}).click()
  await expect(monitor.getByText('참가 상태: 참가 제한 · 검토 완료',{exact:true})).toBeVisible()
  await monitor.screenshot({path:'../.local/safety-review-mobile.png'})
  const payment=await request.post(api+'/intake/payment',{headers:headers(targetToken),data:{applicationId:db(`select id from app_private.intake_applications where id=md5('${label}2app')::uuid;`),requestKey:randomUUID(),outcome:'success'}})
  expect(payment.status()).toBe(403);expect((await payment.json()).error.code).toBe('PARTICIPATION_RESTRICTED')
  const submit=await request.post(api+'/intake/submit',{headers:headers(targetToken),data:{requestKey:randomUUID()}})
  expect(submit.status()).toBe(403)
  await login(target)
  await expect(panel.getByText('내 상태: 참가 제한',{exact:true})).toBeVisible()
  await page.getByRole('link',{name:'내 식탁',exact:true}).click()
  const matching=page.getByRole('region',{name:'나의 매칭 상태',exact:true})
  const resolve=matching.getByRole('form',{name:'신청 해결 선택',exact:true})
  await resolve.getByLabel('처리 방법',{exact:true}).selectOption('refund')
  await resolve.getByRole('checkbox').check();await resolve.getByRole('button',{name:'선택한 처리 실행',exact:true}).click()
  await expect.poll(()=>db(`select payment_status from app_private.intake_applications where id=md5('${label}2app')::uuid;`)).toBe('REFUNDED')
  await login(operator);await page.getByRole('link',{name:'운영 관리',exact:true}).click();await page.getByRole('button',{name:'안전·개인정보',exact:true}).click();await monitor.getByRole('button',{name:`사건 상세 확인 ${reportId.slice(0,8)}`,exact:true}).click()
  await actionForm.getByLabel('조치 선택',{exact:true}).selectOption('RESTORE');await actionForm.getByLabel('조치 사유 (5~500자, 내부 기록)',{exact:true}).fill('LOCAL 검토 후 참가 제한 해제')
  await actionForm.getByRole('checkbox').check();await actionForm.getByRole('button',{name:'안전 조치 저장',exact:true}).click();await expect(monitor.getByText('참가 상태: 참가 가능 · 검토 완료',{exact:true})).toBeVisible()
  expect(db(`select payment_status from app_private.intake_applications where id=md5('${label}2app')::uuid;`)).toBe('REFUNDED')
  db(`delete from app_private.safety_reviewers where user_id='${operator.id}';`)
  expect((await request.post(api+'/operations/safety/detail',{headers:headers(await auth(operator)),data:detailBody})).status()).toBe(403)
  await monitor.getByRole('button',{name:'안전 검토 새로고침',exact:true}).click();await expect(monitor.getByText(secret,{exact:true})).toHaveCount(0)
  // Isolate the next-round fixture from leftover source applications, then let real Cron match.
  db(`update app_private.intake_applications set application_status='CANCELED',matching_status='NO_MATCH' where input->'slotIds' ? ${slot}::text;`)
  const started=db('select clock_timestamp();')
  db(prefix+`select pg_temp.next_people('${next}','${label}',8);
   update app_private.intake_applications set user_id=case when id=md5('${next}1app')::uuid then '${reporter.id}'::uuid else '${target.id}'::uuid end where id in(md5('${next}1app')::uuid,md5('${next}2app')::uuid);
   update app_private.payment_attempts p set user_id=a.user_id from app_private.intake_applications a where p.application_id=a.id and a.input->'slotIds' ? md5('${next}slot')::uuid::text;commit;`)
  await expect.poll(()=>db(`select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where a.active and t.slot_id=md5('${next}slot')::uuid;`),{timeout:80000,intervals:[1500,2500]}).toBe('8')
  expect(db(`select count(*) from app_private.table_assignments a join app_private.table_assignments b on b.table_id=a.table_id join app_private.dining_tables t on t.id=a.table_id where a.active and b.active and t.slot_id=md5('${next}slot')::uuid and a.user_id='${reporter.id}' and b.user_id='${target.id}';`)).toBe('0')
  expect(Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-matching-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`))).toBeGreaterThan(0)
 }finally{
  db(`begin;delete from app_private.safety_actions where case_id in(select id from app_private.safety_reports where assignment_id in(${assignments}));
   delete from app_private.safety_commands where actor_id in('${reporter.id}','${target.id}','${operator.id}');delete from app_private.safety_exclusions where user_low=least('${reporter.id}'::uuid,'${target.id}'::uuid) and user_high=greatest('${reporter.id}'::uuid,'${target.id}'::uuid);
   delete from app_private.safety_reviewers where user_id='${operator.id}';${originalState.exists?`update app_private.safety_accounts set state='${originalState.state}',revision=${Number(originalState.revision)} where user_id='${target.id}';`:`delete from app_private.safety_accounts where user_id='${target.id}';`}
   delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});delete from app_private.match_resolutions where application_id in(${apps});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slots})) or aggregate_id in(${apps});delete from app_private.allocation_attempts where application_id in(${apps});
   delete from app_private.table_assignments where application_id in(${apps});delete from app_private.dining_tables where slot_id in(${slots});delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slots}));delete from app_private.match_jobs where slot_id in(${slots});
   delete from app_private.refund_attempts where application_id in(${apps});delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id in(${slots});
   delete from app_private.member_audit where actor_id in(${fakeUsers}) or (actor_id in('${reporter.id}','${target.id}','${operator.id}') and action like 'SAFETY_%');delete from app_private.member_accounts where user_id in(${fakeUsers});delete from auth.users where id in(${fakeUsers});commit;`)
 }
})
