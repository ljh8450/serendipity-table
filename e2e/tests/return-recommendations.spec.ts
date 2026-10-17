import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db = (q: string) => execFileSync('docker', ['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'], { input:q, encoding:'utf8', stdio:['pipe','pipe','pipe'] }).trim()

test('mobile next dining recommendations require explicit choice and preserve server eligibility', async ({page,request}) => {
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const user=data.users[3],label=`e2e-return-${randomUUID()}`
 const slot=`md5('${label}slot')::uuid`,future=`md5('${label}future')::uuid`,later=`md5('${label}later')::uuid`,slots=`${slot},${future},${later}`
 const apps=`select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text`
 const assignments=`select id from app_private.table_assignments where application_id in(${apps})`
 const users=Array.from({length:4},(_,i)=>`md5('${label}${i+1}user')::uuid`).join(',')
 const prefix=readFileSync(path.resolve('../supabase/tests/preferences_permissions.sql'),'utf8').split('do $$ declare s uuid')[0]
 db(prefix+`select pg_temp.match_fixture('${label}',4);
 insert into app_private.member_accounts(user_id) values('${user.id}') on conflict do nothing;
 update app_private.intake_applications set user_id='${user.id}',onboarding_snapshot=jsonb_set(onboarding_snapshot,'{gender}','"male"') where id=md5('${label}1app')::uuid;
 update app_private.payment_attempts set user_id='${user.id}' where application_id=md5('${label}1app')::uuid;
 select app_private.matching_tick();select app_private.chat_tick();
 update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '4 hours',closes_at=clock_timestamp()-interval '5 hours',matches_at=clock_timestamp()-interval '5 hours' where id=${slot};
 update app_private.intake_applications set attendance_status='ATTENDED' where input->'slotIds' ? ${slot}::text;
 update app_private.table_assignments ta set occupied_at=tstzrange(s.starts_at,s.starts_at+interval '3 hours','[)') from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id where ta.table_id=t.id and t.slot_id=${slot};
 insert into app_private.event_feedback(assignment_id,user_id,request_key,ratings) select id,user_id,gen_random_uuid(),'{"atmosphere":5,"conversation":5,"venue":5,"revisit":true,"recommend":true}' from app_private.table_assignments where user_id='${user.id}' and application_id in(${apps});
 insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity) values
 (${future},clock_timestamp()+interval '2 days',clock_timestamp()-interval '1 day',clock_timestamp()+interval '1 day',clock_timestamp()+interval '1 day','hongdae','추천 모바일 회차',true,24),
 (${later},clock_timestamp()+interval '3 days',clock_timestamp()-interval '1 day',clock_timestamp()+interval '1 day',clock_timestamp()+interval '1 day','hongdae','추천 다음 회차',true,24);commit;`)
 try {
  let first=true
  await page.route('**/member/return-recommendations',async route=>{if(first){first=false;await route.abort('failed')}else await route.continue()})
  await page.goto('/');await page.getByLabel('이메일',{exact:true}).fill(user.email);await page.getByLabel('비밀번호',{exact:true}).fill(user.password);await page.getByRole('button',{name:'로그인',exact:true}).click()
  const panel=page.getByRole('region',{name:'다음 식탁 추천',exact:true})
  await expect(panel.getByRole('alert')).toBeVisible()
  await panel.getByRole('button',{name:'다음 모집 새로고침',exact:true}).click()
  await expect(panel.getByRole('button',{name:/이 일정으로 신청서 작성 · 추천 모바일 회차/})).toBeVisible()
  await expect(panel.getByText('다시 방문하고 싶다고 답한 식탁의 지역이에요.').first()).toBeVisible()
  const before=db(`select count(*) from app_private.intake_applications where user_id='${user.id}';`)
  const draftBefore=db(`select coalesce(jsonb_agg(to_jsonb(d)),'[]') from app_private.intake_drafts d where user_id='${user.id}';`)
  db(`update app_private.intake_event_slots set published=false where id=${future};`)
  await panel.getByRole('button',{name:/이 일정으로 신청서 작성 · 추천 모바일 회차/}).click()
  await expect(panel.getByRole('alert')).toContainText('새로고침')
  db(`update app_private.intake_event_slots set published=true where id=${future};`)
  await panel.getByRole('button',{name:'다음 모집 새로고침',exact:true}).click()
  await panel.getByRole('button',{name:/이 일정으로 신청서 작성 · 추천 모바일 회차/}).click()
  await expect(panel.getByRole('status')).toContainText('아직 신청·결제되지 않았어요.')
  await expect(page.getByRole('heading',{name:'이번 회차 신청',exact:true})).toBeFocused()
  const choices=page.getByRole('group',{name:'참가 가능한 일정·지역 (필수·복수 선택)',exact:true})
  await expect(choices.locator('input:checked')).toHaveCount(1)
  await expect(choices.getByRole('checkbox',{name:/추천 모바일 회차/})).toBeChecked()
  expect(db(`select count(*) from app_private.intake_applications where user_id='${user.id}';`)).toBe(before)
  expect(db(`select coalesce(jsonb_agg(to_jsonb(d)),'[]') from app_private.intake_drafts d where user_id='${user.id}';`)).toBe(draftBefore)
  await panel.getByRole('button',{name:/이 일정으로 신청서 작성 · 추천 다음 회차/}).click()
  await expect(page.getByRole('heading',{name:'이번 회차 신청',exact:true})).toBeFocused()
  await expect(choices.locator('input:checked')).toHaveCount(1)
  await expect(choices.getByRole('checkbox',{name:/추천 다음 회차/})).toBeChecked()
  expect(await page.locator('body').evaluate(e=>e.scrollWidth)).toBeLessThanOrEqual(390)
  await panel.screenshot({path:'../.local/return-recommendations-mobile.png'})
  const auth=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password}})
  const headers={authorization:`Bearer ${(await auth.json()).access_token}`},api=`${data.apiUrl}/functions/v1/member/return-recommendations`
  expect((await request.get(api+'?actor=other',{headers})).status()).toBe(422)
  const dto=await(await request.get(api,{headers})).json()
  expect(JSON.stringify(dto)).not.toMatch(/user_id|assignmentId|ratings|report|onboarding|birthYear/)
  db(`begin;select pg_advisory_xact_lock(hashtextextended('matching-state',0));insert into app_private.safety_accounts(user_id,state) values('${user.id}','RESTRICTED');commit;`)
  await panel.getByRole('button',{name:'다음 모집 새로고침',exact:true}).click()
  await expect(panel.getByText('참가 제한 중에는 다음 식탁을 추천하지 않아요. 나의 안전 상태를 확인해 주세요.',{exact:true})).toBeVisible()
  await expect(panel.getByRole('button',{name:/이 일정으로 신청서 작성/})).toHaveCount(0)
  db(`delete from app_private.safety_accounts where user_id='${user.id}';update app_private.intake_applications set attendance_status='NO_SHOW' where user_id='${user.id}' and id in(${apps});`)
  await panel.getByRole('button',{name:'다음 모집 새로고침',exact:true}).click()
  await expect(panel.getByText(/참석이 확인된 식탁이 생기면/)).toBeVisible()
 } finally {
  db(`begin;delete from app_private.safety_accounts where user_id='${user.id}';delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
  delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slots})) or aggregate_id in(${apps});delete from app_private.allocation_attempts where application_id in(${apps});
  delete from app_private.table_assignments where application_id in(${apps});delete from app_private.dining_tables where slot_id in(${slots});delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slots}));delete from app_private.match_jobs where slot_id in(${slots});
  delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id in(${slots});
  delete from app_private.member_audit where actor_id in(${users});delete from app_private.member_accounts where user_id in(${users});delete from auth.users where id in(${users});commit;`)
 }
})
