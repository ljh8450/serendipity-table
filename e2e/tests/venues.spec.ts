import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db=(sql:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()

test('operator registers a verified reservation, actual Cron allocates and only its members see the venue',async({page,request})=>{
 test.setTimeout(190000)
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw new Error('Refusing nonlocal fixture')
 const user=data.users[3],operator=data.users[2],label=`e2e-venue-${randomUUID()}`
 const slot=`md5('${label}slot')::uuid`,app=`md5('${label}participant')::uuid`
 const others=[1,2,3].map(i=>`md5('${label}${i}user')::uuid`).join(',')
 const ids=`'${user.id}',${others}`
 const prefix=readFileSync(path.resolve('../supabase/tests/matching_permissions.sql'),'utf8').split('do $$ declare count_n')[0]
 db(prefix+`select pg_temp.match_fixture('${label}',3);insert into app_private.member_accounts(user_id) values('${user.id}') on conflict do nothing;
 insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
 select ${app},'${user.id}',gen_random_uuid(),input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,'PAID' from app_private.intake_applications where id=md5('${label}1app')::uuid;
 insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values('${user.id}',${app},gen_random_uuid(),'success',9900);
 update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["10_20"],"allergies":"","avoidedFoods":""}' where input->'slotIds' ? ${slot}::text;
 select app_private.matching_tick();commit;`)
 const login=async(u:{email:string;password:string})=>{await page.getByLabel('이메일',{exact:true}).fill(u.email);await page.getByLabel('비밀번호',{exact:true}).fill(u.password);await page.getByRole('button',{name:'로그인',exact:true}).click()}
 try{
  await page.goto('/admin');await login(operator);await page.getByRole('button',{name:'모집 준비',exact:true}).click()
  await expect(page.getByRole('heading',{name:'식당 재고·자동 배정',exact:true})).toBeVisible()
  const form=page.getByRole('group',{name:'확인된 예약 재고 등록',exact:true})
  await form.getByLabel('배정 회차 (필수)',{exact:true}).selectOption(db(`select ${slot};`))
  await form.getByLabel('식당 이름 (필수)',{exact:true}).fill('LOCAL VENUE E2E')
  await form.getByLabel('주소 (필수)',{exact:true}).fill('LOCAL TEST ADDRESS')
  await form.getByLabel('지도 HTTPS 링크 (필수)',{exact:true}).fill('https://example.test/map')
  await form.getByLabel('예약명·식탁 식별명 (필수)',{exact:true}).fill(label)
  await form.getByLabel('1인 식사 가격·원 (필수)',{exact:true}).fill('15000')
  await form.getByLabel('예약 좌석 수 (필수·4~6)',{exact:true}).fill('6')
  await form.getByLabel('5점 만점 리뷰 평점 (필수·4.0 이상)',{exact:true}).fill('4.5')
  await form.getByLabel('리뷰 수 (필수·20개 이상)',{exact:true}).fill('40')
  await form.getByLabel('리뷰 출처 HTTPS 링크 (필수)',{exact:true}).fill('https://example.test/review')
  const kst=(ms:number)=>new Date(ms+9*3600000).toISOString().slice(0,16)
  await form.getByLabel('리뷰·예약·메뉴 확인 시각 (필수·한국 시각·최근 7일)',{exact:true}).fill(kst(Date.now()-60000))
  await form.getByLabel('예약 유효시각 (필수·한국 시각·행사 시작 이후)',{exact:true}).fill(kst(Date.now()+8*86400000))
  await form.getByLabel('예약·식사 조건 확인 근거 (필수·운영자 전용)',{exact:true}).fill('LOCAL E2E FIXTURE ONLY')
  await form.getByRole('checkbox',{name:'실제 예약과 위 식사 조건을 식당에 확인했어요.',exact:true}).check()
  await form.getByRole('button',{name:'확인된 식당 재고 등록',exact:true}).click()
  await expect(page.getByText('예약 재고를 등록했어요. 서버가 다음 예약 실행에서 조건을 검사하고 자동 배정해요.',{exact:true})).toBeVisible()
  const auth=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password}})
  const {access_token:token}=await auth.json(),headers={authorization:`Bearer ${token}`}
  await expect.poll(async()=>{const r=await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers});expect(r.status()).toBe(200);return (await r.json()).applications[0]?.table?.venueStatus},{timeout:80000,intervals:[1500,2500]}).toBe('ASSIGNED')
  const dto=await(await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers})).json()
  expect(dto.applications[0].table.venue.name).toBe('LOCAL VENUE E2E')
  expect(JSON.stringify(dto)).not.toMatch(/safeAllergies|verificationNote|reviewUrl|birthYear/)
  expect((await request.get(`${data.apiUrl}/functions/v1/member/operations/venues`,{headers})).status()).toBe(403)
  expect((await request.post(`${data.apiUrl}/functions/v1/member/operations/venues/create`,{headers,data:{}})).status()).toBe(403)
  await page.getByRole('button',{name:'로그아웃',exact:true}).click();await login(user);await page.getByRole('link',{name:'내 식탁',exact:true}).click()
  await expect(page.getByText('식당: LOCAL VENUE E2E',{exact:true})).toBeVisible()
  await expect(page.getByRole('link',{name:'식당 지도 보기',exact:true})).toHaveAttribute('href','https://example.test/map')
  await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390)
  await page.screenshot({path:'test-results/venue-member-mobile.png',fullPage:true})
  const outsider=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:data.users[1].email,password:data.users[1].password}})
  const other=await outsider.json()
  const otherDto=await(await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers:{authorization:`Bearer ${other.access_token}`}})).json()
  expect(JSON.stringify(otherDto)).not.toContain('LOCAL VENUE E2E')
  const cancel=await request.post(`${data.apiUrl}/functions/v1/member/matching/resolve`,{headers,data:{applicationId:db(`select ${app};`),requestKey:randomUUID(),action:'cancel'}})
  expect(cancel.status()).toBe(200)
  const after=await(await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers})).json()
  expect(after.applications[0].table).toBeNull()
  await expect.poll(()=>db(`select count(*) from app_private.venue_allocations va join app_private.dining_tables t on t.id=va.table_id where t.slot_id=${slot} and va.active;`),{timeout:80000,intervals:[1500,2500]}).toBe('0')
 }finally{
  db(`begin;delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(select id from app_private.intake_applications where user_id in(${ids}));
   delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id in(${ids}));
   delete from app_private.table_assignments where user_id in(${ids});delete from app_private.dining_tables where slot_id=${slot};
   delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.refund_attempts where user_id in(${ids});delete from app_private.payment_attempts where user_id in(${ids});delete from app_private.intake_applications where user_id in(${ids});
   delete from app_private.intake_event_slots where id=${slot};delete from app_private.member_audit where actor_id in(${others});delete from app_private.member_accounts where user_id in(${others});delete from auth.users where id in(${others});commit;`)
 }
})
