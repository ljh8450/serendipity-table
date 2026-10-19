import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db = (sql: string) => execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()

test('actual Cron confirms a paid group and authenticated mobile reads only its own result', async ({ page, request }) => {
  test.setTimeout(100000)
  const data = JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8').replace(/^\uFEFF/,''))
  const user = data.users[3]
  if (data.apiUrl !== 'http://127.0.0.1:54331' || !/^[0-9a-f-]{36}$/i.test(user.id)) throw new Error('Refusing nonlocal fixture')
  const label = `e2e-match-${randomUUID()}`
  const slot = `md5('${label}slot')::uuid`
  const appId = `md5('${label}participant')::uuid`
  const others = [1,2,3].map(i => `md5('${label}${i}user')::uuid`).join(',')
  const prefix = readFileSync(path.resolve('../supabase/tests/matching_permissions.sql'),'utf8').replace(/^\uFEFF/,'').split('do $$ declare count_n')[0]
  db(prefix+`select pg_temp.match_fixture('${label}',3);
    insert into app_private.member_accounts(user_id) values('${user.id}') on conflict do nothing;
    insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
    select ${appId},'${user.id}',gen_random_uuid(),input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,'PAID' from app_private.intake_applications where id=md5('${label}1app')::uuid;
    insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values('${user.id}',${appId},gen_random_uuid(),'success',9900);commit;`)
  try {
    const login = await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`, { headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password} })
    const { access_token: token } = await login.json()
    const headers = { authorization:`Bearer ${token}` }
    // Read-only polling never starts the worker; the installed 1-minute Cron is responsible.
    await expect.poll(async () => {
      const response = await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers})
      expect(response.status()).toBe(200)
      return (await response.json()).applications[0]?.status
    },{timeout:80000,intervals:[1500,2500]}).toBe('CONFIRMED')
    const dto = await (await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers})).json()
    expect(dto.applications).toHaveLength(1)
    expect(dto.applications[0].table.count).toBe(4)
    expect(dto.applications[0].explanation.checks.minimumScore).toBe(true)
    expect(dto.applications[0].explanation.checks.exclusions).toBe(true)
    expect(dto.applications[0].table.deliveryStatus).toBe('PENDING')
    expect(JSON.stringify(dto)).not.toMatch(/birthYear|score|instagram|user_low/)
    expect((await request.get(`${data.apiUrl}/functions/v1/member/operations/matching`,{headers})).status()).toBe(403)
    expect((await request.post(`${data.apiUrl}/functions/v1/member/matching/tick`,{headers,data:{}})).status()).toBe(404)
    await page.goto('/#table')
    await page.getByLabel('이메일',{exact:true}).fill(user.email)
    await page.getByLabel('비밀번호',{exact:true}).fill(user.password)
    await page.getByRole('button',{name:'로그인',exact:true}).click()
    await expect(page.getByRole('heading',{name:'매칭 확정',exact:true})).toBeVisible()
    await expect(page.getByText(/LOCAL MATCH TEST · 4명/)).toBeVisible()
    await page.getByText('매칭 이유와 처리 이력', { exact: true }).click()
    await expect(page.getByText('최소 매칭 기준: 충족', { exact: true })).toBeVisible()
    // Render the available room action from server state; do not always claim notices are pending.
    await expect(page.locator('p').filter({hasText:/단체방에서 준비 안내|참가 안내.*준비 중이에요\./})).toBeVisible()
    await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390)
    await page.screenshot({path:'test-results/auto-match-mobile.png',fullPage:true})
    const operator = data.users[2]
    const auth = await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`, { headers:{apikey:data.publishableKey},data:{email:operator.email,password:operator.password} })
    const session = await auth.json()
    const monitor = await request.get(`${data.apiUrl}/functions/v1/member/operations/matching`,{headers:{authorization:`Bearer ${session.access_token}`}})
    expect(monitor.status()).toBe(200)
    const status = await monitor.json()
    expect(status.runs.some((r:{allocated:number})=>r.allocated===4)).toBe(true)
    expect(status.pendingOutbox).toBeGreaterThan(0)
    expect(db(`select count(*) from app_private.match_job_attempts a join app_private.match_jobs j on j.id=a.job_id where j.slot_id=${slot} and a.outcome='COMPLETED';`)).toBe('1')
  } finally {
    db(`begin;
      delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text);
      delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text);
      delete from app_private.table_assignments where application_id in(select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text);
      delete from app_private.dining_tables where slot_id=${slot};
      delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});
      delete from app_private.match_jobs where slot_id=${slot};
      delete from app_private.payment_attempts where application_id in(select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text);
      delete from app_private.intake_applications where input->'slotIds' ? ${slot}::text;
      delete from app_private.member_audit where actor_id in(${others});
      delete from app_private.member_accounts where user_id in(${others});
      delete from auth.users where id in(${others});
      delete from app_private.intake_event_slots where id=${slot};commit;`)
  }
})
