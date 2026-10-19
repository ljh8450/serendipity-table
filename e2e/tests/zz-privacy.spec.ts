import { test,expect } from '@playwright/test'
import { execSync,execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
const db=(q:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('soft withdrawal revokes app/session rights and real server Cron cleans Auth after retention',async({page,request})=>{
 test.setTimeout(270000)
 const local=JSON.parse(execSync('npx --yes supabase@2.121.0 status -o json',{encoding:'utf8',stdio:['ignore','pipe','ignore']}))
 if(local.API_URL!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const api=local.API_URL,email=`privacy-${randomUUID()}@example.test`,password=`${randomUUID()}Aa1!`,adminHeaders={apikey:local.SERVICE_ROLE_KEY,Authorization:`Bearer ${local.SERVICE_ROLE_KEY}`,'Content-Type':'application/json'}
 // Node fetch keeps the administrative credential out of the Playwright trace.
 const created=await fetch(`${api}/auth/v1/admin/users`,{method:'POST',headers:adminHeaders,body:JSON.stringify({email,password,email_confirm:true})})
 if(!created.ok)throw Error('Local disposable Auth creation failed')
 const {id}=await created.json()
 const retention=JSON.parse(db("select json_build_object('id',jobid,'schedule',schedule) from cron.job where jobname='serendipity-privacy-retention'"))
 if(!/^[0-9*,/\s-]+$/.test(retention.schedule))throw Error('Unexpected local retention schedule')
 try{
  const login=await request.post(`${api}/auth/v1/token?grant_type=password`,{headers:{apikey:local.PUBLISHABLE_KEY},data:{email,password}})
  const session=await login.json(),headers={Authorization:`Bearer ${session.access_token}`}
  await page.goto('/#account');await page.getByLabel('이메일',{exact:true}).fill(email);await page.getByLabel('비밀번호',{exact:true}).fill(password);await page.getByRole('button',{name:'로그인',exact:true}).click()
  const panel=page.getByRole('region',{name:'회원 탈퇴·개인정보 보관',exact:true})
  await panel.getByText('탈퇴와 보관 기준 확인',{exact:true}).click()
  await expect(panel.getByText(/확인이 필요한 결제 신청 0건/)).toBeVisible()
  await panel.getByLabel('미래 배정 취소·복원 불가·보관 기준과 남은 금융 권리를 확인했어요.').check()
  await panel.getByLabel('확인 문구 · 탈퇴').fill('잘못된 문구');await panel.getByRole('button',{name:'회원 탈퇴 처리'}).click();await expect(panel.getByRole('alert')).toContainText('탈퇴를 입력')
  await panel.getByLabel('확인 문구 · 탈퇴').fill('탈퇴');await panel.getByRole('button',{name:'회원 탈퇴 처리'}).click()
  await expect(page.getByText('탈퇴를 처리했어요. 개인정보는 안내한 보관 기준에 따라 정리됩니다.',{exact:true})).toBeVisible()
  const downloadEvent=page.waitForEvent('download');await page.getByRole('button',{name:'탈퇴 접수 확인서 저장'}).click();const download=await downloadEvent;expect(download.suggestedFilename()).toMatch(/^dining-withdrawal-.*\.json$/)
  const receipt=JSON.parse(readFileSync((await download.path())!,'utf8'));expect(receipt.withdrawn).toBe(true);expect(receipt.receiptId).toMatch(/^[0-9a-f-]{36}$/);expect(JSON.stringify(receipt)).not.toContain(email)
  expect([401,403]).toContain((await request.get(`${api}/functions/v1/member`,{headers})).status())
  const refresh=await request.post(`${api}/auth/v1/token?grant_type=refresh_token`,{headers:{apikey:local.PUBLISHABLE_KEY},data:{refresh_token:session.refresh_token}});expect(refresh.status()).toBeGreaterThanOrEqual(400)
  expect((await request.post(`${api}/functions/v1/privacy-dispatch`,{data:{}})).status()).toBe(401)
  await expect.poll(()=>db(`select status from app_private.privacy_auth_jobs where user_id='${id}' and kind='SOFT_DELETE'`),{timeout:90000,intervals:[1000]}).toBe('DONE')
  const soft=await fetch(`${api}/auth/v1/admin/users/${id}`,{headers:adminHeaders});expect(soft.status).toBe(200);const softUser=await soft.json();expect(softUser.deleted_at).toBeTruthy();expect(JSON.stringify(softUser)).not.toContain(email)
  const relogin=await request.post(`${api}/auth/v1/token?grant_type=password`,{headers:{apikey:local.PUBLISHABLE_KEY},data:{email,password}});expect(relogin.status()).toBeGreaterThanOrEqual(400)
  // Fast-forward only this disposable subject's retention fixtures, not the API clock.
  const beforeRuns=Number(db(`select count(*) from cron.job_run_details where jobid=${Number(retention.id)} and status='succeeded'`))
  db(`begin;update app_private.member_withdrawals set withdrawn_at=now()-interval '7 years',financial_until=now()-interval '1 day',safety_until=now()-interval '1 day',audit_until=now()-interval '1 day' where user_id='${id}';update app_private.member_audit set occurred_at=now()-interval '7 years' where actor_id='${id}';select cron.alter_job(${Number(retention.id)},schedule=>'* * * * *');commit;`)
  await expect.poll(()=>db(`select status from app_private.privacy_auth_jobs where user_id='${id}' and kind='HARD_DELETE'`),{timeout:150000,intervals:[1000]}).toBe('DONE')
  expect(Number(db(`select count(*) from cron.job_run_details where jobid=${Number(retention.id)} and status='succeeded'`))).toBeGreaterThan(beforeRuns)
  const hard=await fetch(`${api}/auth/v1/admin/users/${id}`,{headers:adminHeaders});expect(hard.status).toBe(404)
  expect(db(`select count(*) from app_private.member_withdrawals where user_id='${id}' and hard_deleted_at is not null`)).toBe('1')
 }finally{
  db(`select cron.alter_job(${Number(retention.id)},schedule=>'${retention.schedule}')`)
  await fetch(`${api}/auth/v1/admin/users/${id}`,{method:'DELETE',headers:adminHeaders})
  db(`begin;delete from app_private.privacy_auth_jobs where user_id='${id}';delete from app_private.privacy_holds where user_id='${id}';delete from app_private.member_withdrawals where user_id='${id}';commit;`)
 }
})
