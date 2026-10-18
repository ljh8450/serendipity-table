import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
const db = (q: string) => execFileSync('docker', ['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'], { input:q, encoding:'utf8', stdio:['pipe','pipe','pipe'] }).trim()

test('operator exception detail focuses the responsible privacy monitor without retrying normal work', async ({ page }) => {
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const subject=randomUUID(),job=randomUUID()
 // This subject has no Auth identity. EXCEPTION is never claimed by the worker.
 db(`insert into app_private.member_withdrawals(user_id,request_key,policy_version,financial_until,safety_until,audit_until) values('${subject}','${randomUUID()}','privacy-v1',now()+interval '1 year',now()+interval '1 year',now()+interval '1 year');insert into app_private.privacy_auth_jobs(id,user_id,kind,status,attempts) values('${job}','${subject}','SOFT_DELETE','EXCEPTION',5);`)
 try {
  await page.goto('/');await page.getByLabel('이메일',{exact:true}).fill(data.users[2].email);await page.getByLabel('비밀번호',{exact:true}).fill(data.users[2].password);await page.getByRole('button',{name:'로그인',exact:true}).click()
  const panel=page.getByRole('region',{name:/^운영 통합 조회 ·/})
  await panel.getByLabel('조회 대상',{exact:true}).selectOption('exceptions')
  await panel.getByLabel('아이디·식별자·지역 검색').fill(job);await panel.getByRole('button',{name:'조건 적용',exact:true}).click()
  await expect(panel.getByText('총 1건 · 1페이지')).toBeVisible()
  await panel.getByRole('button',{name:'예외 상세 보기'}).click()
  await panel.getByRole('button',{name:'담당 업무 모니터로 이동'}).click()
  await expect(page.getByRole('heading',{name:'탈퇴·보존 만료 정리',exact:true})).toBeFocused()
  expect(db(`select status||':'||attempts from app_private.privacy_auth_jobs where id='${job}'`)).toBe('EXCEPTION:5')
 } finally { db(`delete from app_private.member_withdrawals where user_id='${subject}'`) }
})

test('operator mobile explorer preserves filters across linked details and fails closed', async ({ page, request }) => {
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const user=data.users[2]
 let fail=true
 await page.route('**/member/operations/explore',async route=>{if(fail){fail=false;await route.abort('failed')}else await route.continue()})
 await page.goto('/');await page.getByLabel('이메일',{exact:true}).fill(user.email);await page.getByLabel('비밀번호',{exact:true}).fill(user.password);await page.getByRole('button',{name:'로그인',exact:true}).click()
 const panel=page.getByRole('region',{name:/^운영 통합 조회 ·/})
 await expect(panel.getByRole('alert')).toBeVisible()
 await panel.getByRole('button',{name:'통합 조회 새로고침'}).click()
 await expect(panel.getByText(/총 \d+건/)).toBeVisible()
 await panel.getByLabel('조회 대상',{exact:true}).selectOption('members')
 const username=db(`select username from app_private.member_accounts where user_id='${user.id}'`)
 await panel.getByLabel('아이디·식별자·지역 검색').fill(username || user.id)
 await panel.getByRole('button',{name:'조건 적용',exact:true}).click()
 await expect(panel.getByText('총 1건 · 1페이지')).toBeVisible()
 const downloadEvent=page.waitForEvent('download')
 await panel.getByRole('button',{name:'현재 조건 CSV 내보내기'}).click()
 const download=await downloadEvent
 expect(download.suggestedFilename()).toMatch(/^dining-members-.*\.csv$/)
 const file=await download.path()
 expect(file).toBeTruthy()
 const csv=readFileSync(file!,'utf8')
 expect(csv.startsWith('\uFEFF')).toBe(true);expect(csv).toContain(user.id);expect(csv).not.toContain(user.email)
 await expect(panel.getByText(/현재 적용한 조건으로 1건을 내보냈어요/)).toBeVisible()
 await panel.getByRole('button',{name:'회원 상세 보기'}).click()
 await expect(panel.getByRole('heading',{name:'운영 통합 조회 · 회원 상세'})).toBeFocused()
 await panel.getByRole('button',{name:'회원 신청 목록'}).click()
 await expect(panel.getByText(/선택한 회원에 연결된 결과/)).toBeVisible()
 await panel.getByRole('button',{name:'이전 목록으로'}).click()
 await expect(panel.getByRole('heading',{name:'운영 통합 조회 · 회원 상세'})).toBeFocused()
 await panel.getByRole('button',{name:'이전 목록으로'}).click()
 await expect(panel.getByLabel('아이디·식별자·지역 검색')).toHaveValue(username || user.id)
 await expect(panel.getByLabel('조회 대상',{exact:true})).toHaveValue('members')
 await expect(panel.getByText('총 1건 · 1페이지')).toBeVisible()
 // No page overflow at 320px, including full UUIDs and the filters.
 await page.setViewportSize({width:320,height:844})
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
 const signIn=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:data.users[0].email,password:data.users[0].password}})
 const session=await signIn.json()
 const denied=await request.post(`${data.apiUrl}/functions/v1/member/operations/explore`,{headers:{Authorization:`Bearer ${session.access_token}`},data:{kind:'members'}})
 expect(denied.status()).toBe(403)
 expect((await request.post(`${data.apiUrl}/functions/v1/member/operations/export`,{headers:{Authorization:`Bearer ${session.access_token}`},data:{kind:'members'}})).status()).toBe(403)
 const ownSignIn=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password}})
 const own=await ownSignIn.json();const headers={Authorization:`Bearer ${own.access_token}`}
 expect((await request.post(`${data.apiUrl}/functions/v1/member/operations/explore?actorId=forged`,{headers,data:{kind:'members'}})).status()).toBe(422)
 const dto=await request.post(`${data.apiUrl}/functions/v1/member/operations/explore`,{headers,data:{kind:'members',id:user.id}})
 expect(dto.status()).toBe(200)
 expect(Object.keys((await dto.json()).items[0]).sort()).toEqual(['kind','id','label','status','memberId','slotId','tableId','applicationId','at','facts'].sort())
 await panel.screenshot({path:'../.local/operations-explorer-mobile.png'})
})
