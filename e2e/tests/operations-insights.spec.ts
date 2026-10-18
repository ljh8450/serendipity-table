import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db = (q:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('scoped mobile feedback and safety cases preserve candidate and reviewer boundaries',async({page,request})=>{
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const user=data.users[2],sql=readFileSync(path.resolve('../supabase/tests/operations_insights_permissions.sql'),'utf8').split('set local role app_member_api;')[0]
 db(sql+'commit;')
 try{
  await page.goto('/');await page.getByLabel('이메일',{exact:true}).fill(user.email);await page.getByLabel('비밀번호',{exact:true}).fill(user.password);await page.getByRole('button',{name:'로그인',exact:true}).click()
  const panel=page.getByRole('region',{name:/^운영 통합 조회 ·/})
  await panel.getByLabel('조회 대상',{exact:true}).selectOption('tables');await panel.getByLabel('아이디·식별자·지역 검색').fill('OP01 TEST');await panel.getByRole('button',{name:'조건 적용',exact:true}).click()
  await panel.getByRole('button',{name:'테이블 상세 보기'}).click()
  const insights=page.getByRole('region',{name:'참석·피드백·연결 사건',exact:true})
  await expect(insights.getByText(/현재 배정 3명 · 참석 1명 · 노쇼 후보 1명 · 확인 노쇼 1명/)).toBeVisible()
  await expect(insights.getByText(/피드백 1 \/ 대상 1건 · 응답률 100.0%/)).toBeVisible()
  await expect(insights.getByText(/분위기 5.00 \/ 5/)).toBeVisible()
  await expect(insights.getByText('사건 원문과 조치는 별도 안전 검토 권한이 필요해요.').first()).toBeVisible()
  await expect(insights.getByRole('button',{name:'권한 있는 사건 상세로 연결'})).toHaveCount(0)
  await expect(page.getByText('PRIVATE_REPORT_TEXT',{exact:true})).toHaveCount(0)
  await insights.getByRole('button',{name:'참석 후보 검토로 이동'}).click()
  await expect(page.getByRole('heading',{name:'참석·노쇼 후보 검토'})).toBeFocused()
  // Grant only this disposable local operator; the server remains the authority.
  db(`insert into app_private.safety_reviewers(user_id) values('${user.id}')`)
  await insights.getByRole('button',{name:'집계 새로고침'}).click()
  await insights.getByRole('button',{name:'권한 있는 사건 상세로 연결'}).first().click()
  await expect(page.getByRole('heading',{name:'안전 신고·참가 제한 검토'})).toBeFocused()
  const login=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password}})
  const session=await login.json(),headers={Authorization:`Bearer ${session.access_token}`}
  const table=db("select md5('op01-table')::uuid"),other=db("select md5('op01-other-slot')::uuid")
  expect((await request.post(`${data.apiUrl}/functions/v1/member/operations/insights`,{headers,data:{tableId:table,slotId:other}})).status()).toBe(422)
  db(`delete from app_private.safety_reviewers where user_id='${user.id}'`)
  await insights.getByRole('button',{name:'집계 새로고침'}).click()
  await expect(insights.getByRole('button',{name:'권한 있는 사건 상세로 연결'})).toHaveCount(0)
  await insights.screenshot({path:'../.local/operations-insights-mobile.png'})
 }finally{
  db(`begin;
  delete from app_private.safety_reviewers where user_id='${user.id}';
  delete from app_private.safety_reports where id=md5('op02-report')::uuid;
  delete from app_private.feedback_jobs where assignment_id in(select id from app_private.table_assignments where table_id=md5('op01-table')::uuid);
  delete from app_private.attendance_actions where assignment_id in(select id from app_private.table_assignments where table_id=md5('op01-table')::uuid);
  delete from app_private.attendance_records where assignment_id in(select id from app_private.table_assignments where table_id=md5('op01-table')::uuid);
  delete from app_private.table_assignments where table_id=md5('op01-table')::uuid;
  delete from app_private.dining_tables where id=md5('op01-table')::uuid;
  delete from app_private.match_runs where id=md5('op01-run')::uuid;
  delete from app_private.intake_event_slots where id in(md5('op01-slot')::uuid,md5('op01-other-slot')::uuid);
  delete from auth.users where id in(select md5('op01-user-'||i)::uuid from generate_series(0,27)i);
  commit;`)
 }
})
