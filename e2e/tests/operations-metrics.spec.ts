import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db=(q:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('13 operator metrics expose denominators and server-only work time',async({page,request})=>{
 const f=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(f.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const user=f.users[2],slot=db("select id from app_private.intake_event_slots order by starts_at limit 1")
 try{
  await page.goto('/');await page.getByLabel('이메일',{exact:true}).fill(user.email);await page.getByLabel('비밀번호',{exact:true}).fill(user.password);await page.getByRole('button',{name:'로그인',exact:true}).click()
  const panel=page.getByRole('region',{name:'운영 대시보드 · 13개 지표',exact:true})
  await expect(panel.locator('article')).toHaveCount(13)
  await expect(panel.getByText('N/A · 미계측',{exact:true})).toBeVisible()
  await panel.getByLabel('시간을 기록할 회차').selectOption(slot)
  await panel.getByRole('button',{name:'예외 처리 시간 기록 시작'}).click()
  await expect(panel.getByText(/내 진행 세션/)).toBeVisible()
  await page.reload();await expect(panel.getByText(/내 진행 세션/)).toBeVisible()
  await panel.getByRole('button',{name:'예외 처리 시간 기록 종료'}).click()
  await expect(panel.getByText('완료 세션 1건 · 미종료 세션 0건')).toBeVisible()
  await expect(panel.getByText(/분 \/ 측정 회차 · 부분 측정/)).toBeVisible()
  const auth=await request.post(`${f.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:f.publishableKey},data:{email:f.users[0].email,password:f.users[0].password}})
  const {access_token}=await auth.json(),headers={Authorization:`Bearer ${access_token}`}
  expect((await request.post(`${f.apiUrl}/functions/v1/member/operations/metrics`,{headers,data:{from:'2026-01-01T00:00:00Z',to:'2027-01-01T00:00:00Z'}})).status()).toBe(403)
  await page.setViewportSize({width:320,height:844});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
  await panel.screenshot({path:'../.local/operations-metrics-mobile.png'})
 }finally{db(`delete from app_private.operations_work_sessions where actor_id='${user.id}'`)}
})
