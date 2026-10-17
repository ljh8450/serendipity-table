import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db = (sql: string) => execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('actual feedback Cron requests once, reminds once; mobile private ratings survive lost-response retry', async ({ page, request }) => {
 test.setTimeout(220000)
 const data = JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if (data.apiUrl !== 'http://127.0.0.1:54331') throw new Error('Nonlocal fixture refused')
 const user = data.users[3], operator = data.users[2], label = `e2e-feedback-${randomUUID()}`
 const slot = `md5('${label}slot')::uuid`, app = `md5('${label}primary')::uuid`
 const apps = `select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text`
 const assignments = `select id from app_private.table_assignments where application_id in(${apps})`
 const others = [1,2,3].map(i => `md5('${label}${i}user')::uuid`).join(',')
 const prefix = readFileSync(path.resolve('../supabase/tests/matching_permissions.sql'),'utf8').split('do $$ declare count_n')[0]
 db(prefix+`select pg_temp.match_fixture('${label}',3);
 insert into app_private.member_accounts(user_id) values('${user.id}') on conflict do nothing;
 insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
 select ${app},'${user.id}',gen_random_uuid(),input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,'PAID' from app_private.intake_applications where id=md5('${label}1app')::uuid;
 insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values('${user.id}',${app},gen_random_uuid(),'success',9900);
 select app_private.matching_tick();
 update app_private.intake_applications set attendance_status='ATTENDED' where id=${app};
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=${slot};commit;`)

 const login = async (u: { email: string; password: string }) => { await page.goto('/'); await page.getByLabel('이메일',{exact:true}).fill(u.email); await page.getByLabel('비밀번호',{exact:true}).fill(u.password); await page.getByRole('button',{name:'로그인',exact:true}).click() }
 const jobWhere = `assignment_id in(${assignments})`
 try {
  const started = db('select clock_timestamp();')
  await expect.poll(() => db(`select count(*) from app_private.feedback_jobs where ${jobWhere} and kind='REQUEST' and status='DONE';`),{timeout:80000,intervals:[1500,2500]}).toBe('1')
  await login(user)
  const panel = page.getByRole('region',{name:'식탁 평가',exact:true})
  await expect(panel.getByLabel('식탁 분위기 (1~5점)',{exact:true})).toBeVisible()
  await page.getByRole('button',{name:'알림 새로고침',exact:true}).click()
  await expect(page.getByRole('region',{name:/나의 알림/}).getByText('식탁은 어떠셨나요? 평가를 남겨 주세요',{exact:true})).toBeVisible()
  await expect.poll(() => db(`select count(*) from app_private.feedback_jobs where ${jobWhere} and kind='REMINDER';`),{timeout:80000,intervals:[1500,2500]}).toBe('1')
  db(`update app_private.feedback_jobs set due_at=clock_timestamp() where ${jobWhere} and kind='REMINDER';`)
  await expect.poll(() => db(`select count(*) from app_private.feedback_jobs where ${jobWhere} and kind='REMINDER' and status='DONE';`),{timeout:80000,intervals:[1500,2500]}).toBe('1')
  expect(Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-feedback-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`))).toBeGreaterThan(0)
  await panel.getByLabel('식탁 분위기 (1~5점)',{exact:true}).selectOption('4')
  await panel.getByLabel('대화 만족도 (1~5점)',{exact:true}).selectOption('5')
  await panel.getByLabel('식당 만족도 (1~5점)',{exact:true}).selectOption('3')
  await panel.getByRole('group',{name:'다시 참여하고 싶으신가요?',exact:true}).getByLabel('네',{exact:true}).check()
  await panel.getByRole('group',{name:'지인에게 추천하고 싶으신가요?',exact:true}).getByLabel('아니요',{exact:true}).check()
  await panel.screenshot({path:'../.local/feedback-form-mobile.png'})
  let lost=false;const keys: string[]=[]
  await page.route('**/member/feedback/submit',async route=>{
   keys.push(route.request().postDataJSON().requestKey)
   if(!lost){lost=true;const responses=await Promise.all([route.fetch(),route.fetch()]);for(const response of responses)expect(response.status()).toBe(200);await route.abort('failed')}
   else await route.continue()
  })
  await panel.getByRole('button',{name:'식탁 평가 제출',exact:true}).click()
  await expect(panel.getByRole('alert')).toBeVisible()
  await expect(panel.getByLabel('대화 만족도 (1~5점)',{exact:true})).toHaveValue('5')
  await panel.getByRole('button',{name:'식탁 평가 제출',exact:true}).click()
  await expect(panel.getByText('식탁 평가를 제출했어요.',{exact:true})).toBeVisible()
  expect(keys).toHaveLength(2);expect(keys[0]).toBe(keys[1])
  expect(db(`select count(*) from app_private.event_feedback where assignment_id in(${assignments});`)).toBe('1')
  db('select app_private.feedback_tick();select app_private.feedback_tick();')
  expect(db(`select count(*) from app_private.member_notifications where application_id=${app} and kind='FEEDBACK_REMINDER';`)).toBe('1')
  await page.getByRole('button',{name:'알림 새로고침',exact:true}).click()
  await expect(page.getByRole('region',{name:/나의 알림/}).getByText(/식탁은 어떠셨나요|식탁 평가를 한 번 더/)).toHaveCount(0)
  await panel.screenshot({path:'../.local/feedback-submitted-mobile.png'})
  const auth=async(u: {email:string;password:string})=>{const r=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:u.email,password:u.password}});return (await r.json()).access_token}
  const token=await auth(user),headers={authorization:`Bearer ${token}`}
  expect((await request.get(`${data.apiUrl}/functions/v1/member/operations/feedback`,{headers})).status()).toBe(403)
  const otherToken=await auth(data.users[1])
  const other=await request.get(`${data.apiUrl}/functions/v1/member/feedback`,{headers:{authorization:`Bearer ${otherToken}`}})
  expect((await other.json()).events).toHaveLength(0)
  const opToken=await auth(operator)
  const monitor=await request.get(`${data.apiUrl}/functions/v1/member/operations/feedback`,{headers:{authorization:`Bearer ${opToken}`}})
  expect(monitor.status()).toBe(200);expect(JSON.stringify(await monitor.json())).not.toMatch(/ratings|revisit|recommend|assignmentId/)
  db(`update app_private.intake_applications set attendance_status='NO_SHOW' where id=${app};`)
  await panel.getByRole('button',{name:'식탁 평가 새로고침',exact:true}).click()
  await expect(panel.getByText('평가할 식탁이 없어요. 행사 종료 후 참석이 확인되면 여기에 표시돼요.',{exact:true})).toBeVisible()
 } finally {
  db(`begin;delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(${apps});
   delete from app_private.allocation_attempts where application_id in(${apps});delete from app_private.table_assignments where application_id in(${apps});
   delete from app_private.dining_tables where slot_id=${slot};delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id=${slot};
   delete from app_private.member_audit where actor_id in(${others});delete from app_private.member_accounts where user_id in(${others});delete from auth.users where id in(${others});commit;`)
 }
})
