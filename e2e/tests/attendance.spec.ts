import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db = (sql: string) => execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('mobile check-in retries once; actual end Cron creates candidates and operator reviews without automatic restrictions', async ({ page, request }) => {
 test.setTimeout(125000)
 const data = JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if (data.apiUrl !== 'http://127.0.0.1:54331') throw new Error('Nonlocal fixture refused')
 const user = data.users[3], operator = data.users[2], label = `e2e-attendance-${randomUUID()}`
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
 update app_private.intake_event_slots set starts_at=clock_timestamp()+interval '10 minutes' where id=${slot};commit;`)
 const login = async (u: { email: string; password: string }) => { await page.goto('/#table'); await page.getByLabel('이메일',{exact:true}).fill(u.email); await page.getByLabel('비밀번호',{exact:true}).fill(u.password); await page.getByRole('button',{name:'로그인',exact:true}).click() }
 try {
  await login(user)
  const panel = page.getByRole('region',{name:'나의 참석',exact:true})
  await expect(panel.getByRole('button',{name:'도착 체크인'})).toBeVisible()
  let lost = false; const keys: string[] = []
  await page.route('**/member/attendance/check-in',async route => {
   keys.push(route.request().postDataJSON().requestKey)
   if (!lost) { lost=true; const responses=await Promise.all([route.fetch(),route.fetch()]); for(const response of responses) expect(response.status()).toBe(200); await route.abort('failed') }
   else await route.continue()
  })
  await panel.getByRole('button',{name:'도착 체크인'}).click()
  await expect(panel.getByRole('alert')).toBeVisible()
  await panel.getByRole('button',{name:'도착 체크인'}).click()
  await expect(panel.getByText('참석 확인됨',{exact:true})).toBeVisible()
  expect(keys).toHaveLength(2); expect(keys[0]).toBe(keys[1])
  await panel.screenshot({ path: '../.local/attendance-mobile.png' })
  expect(db(`select count(*) from app_private.attendance_actions where assignment_id in(${assignments}) and action='CHECK_IN';`)).toBe('1')
  const started = db('select clock_timestamp();')
  db(`update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=${slot};`)
  await expect.poll(() => db(`select count(*) from app_private.attendance_records where assignment_id in(${assignments}) and review_status='PENDING';`),{timeout:80000,intervals:[1500,2500]}).toBe('3')
  expect(Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-attendance-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`))).toBeGreaterThan(0)
  expect(db(`select count(*) from app_private.intake_applications where id in(${apps}) and attendance_status='NO_SHOW';`)).toBe('0')
  await page.getByRole('button',{name:'로그아웃',exact:true}).click(); await login(operator);await page.getByRole('button',{name:'안전·개인정보',exact:true}).click()
  const monitor = page.getByRole('region',{name:'참석·노쇼 후보 검토',exact:true})
  const form = monitor.locator('form').first()
  await form.getByLabel('확인 결과',{exact:true}).selectOption('NO_SHOW')
  await form.getByLabel('확인 근거 (5~500자, 개인정보 입력 금지)',{exact:true}).fill('가상 행사 참석 여부를 확인했습니다.')
  await form.getByRole('checkbox').check()
  await form.getByRole('button',{name:'참석 검토 저장',exact:true}).click()
  await expect(monitor.getByText('검토 상태: 노쇼 확인',{exact:true})).toBeVisible()
  await monitor.screenshot({ path: '../.local/attendance-operations-mobile.png' })
  expect(db(`select count(*) from app_private.member_accounts where user_id in(${others}) and restricted;`)).toBe('0')
  const auth = await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password}})
  const token=(await auth.json()).access_token
  expect((await request.get(`${data.apiUrl}/functions/v1/member/operations/attendance`,{headers:{authorization:`Bearer ${token}`}})).status()).toBe(403)
 } finally {
  db(`begin;delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(${apps});
   delete from app_private.allocation_attempts where application_id in(${apps});delete from app_private.table_assignments where application_id in(${apps});
   delete from app_private.dining_tables where slot_id=${slot};delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id=${slot};
   delete from app_private.member_audit where actor_id in(${others});delete from app_private.member_accounts where user_id in(${others});delete from auth.users where id in(${others});commit;`)
 }
})
