import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db=(q:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()
test('mobile private avoid survives lost response and actual Cron separates the next round',async({page,request})=>{
 test.setTimeout(150000)
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 const user=data.users[3],label=`e2e-person-${randomUUID()}`,next=label+'next'
 const slot=`md5('${label}slot')::uuid`,slots=`${slot},md5('${next}slot')::uuid`
 const apps=`select id from app_private.intake_applications where input->'slotIds' ?| array[${slot}::text,md5('${next}slot')::uuid::text]`
 const assignments=`select id from app_private.table_assignments where application_id in(${apps})`
 const users=[label,next].flatMap(l=>Array.from({length:8},(_,i)=>`md5('${l}${i+1}user')::uuid`)).join(',')
 const prefix=readFileSync(path.resolve('../supabase/tests/preferences_permissions.sql'),'utf8').split('do $$ declare s uuid')[0]
 db(prefix+`select pg_temp.match_fixture('${label}',4);insert into app_private.member_accounts(user_id) values('${user.id}') on conflict do nothing;
  update app_private.intake_applications set user_id='${user.id}',onboarding_snapshot=jsonb_set(onboarding_snapshot,'{gender}','"male"') where id=md5('${label}1app')::uuid;
  update app_private.payment_attempts set user_id='${user.id}' where application_id=md5('${label}1app')::uuid;
  select app_private.matching_tick();select app_private.chat_tick();
  update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '3 hours',closes_at=clock_timestamp()-interval '4 hours',matches_at=clock_timestamp()-interval '4 hours' where id=${slot};
  update app_private.intake_applications set attendance_status='ATTENDED' where input->'slotIds' ? ${slot}::text;
  update app_private.table_assignments ta set occupied_at=tstzrange(s.starts_at,s.starts_at+interval '3 hours','[)') from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id where ta.table_id=t.id and t.slot_id=${slot};commit;`)
 try{
  await page.goto('/#history');await page.getByLabel('이메일',{exact:true}).fill(user.email);await page.getByLabel('비밀번호',{exact:true}).fill(user.password);await page.getByRole('button',{name:'로그인',exact:true}).click()
  const panel=page.getByRole('region',{name:'참석 이력·비공개 사람 선택',exact:true})
  await expect(panel.getByRole('combobox')).toHaveCount(3)
  const select=panel.getByRole('combobox').first(),form=select.locator('..')
  const peerId=(await select.getAttribute('id'))!.slice('person-'.length)
  await select.selectOption('AVOID');await form.getByRole('checkbox').check()
  let lost=false;const keys:string[]=[]
  await page.route('**/member/preferences/save',async route=>{keys.push(route.request().postDataJSON().requestKey);if(!lost){lost=true;const rs=await Promise.all([route.fetch(),route.fetch()]);for(const r of rs)expect(r.status()).toBe(200);await route.abort('failed')}else await route.continue()})
  await form.getByRole('button').click();await expect(panel.getByRole('alert')).toBeVisible();await expect(select).toHaveValue('AVOID')
  await form.getByRole('button').click();await expect(panel.getByRole('status')).toHaveText('비공개 선택을 저장했어요. 최신 매칭 상태도 확인해 주세요.')
  expect(keys).toHaveLength(2);expect(keys[0]).toBe(keys[1])
  expect(db(`select count(*) from app_private.preference_commands where user_id='${user.id}';`)).toBe('1')
  const target=db(`select user_id from app_private.table_assignments where id='${peerId}';`)
  const auth=async(u:{email:string;password:string})=>{const r=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:u.email,password:u.password}});return(await r.json()).access_token}
  const token=await auth(user),headers={authorization:`Bearer ${token}`}
  const response=await request.get(`${data.apiUrl}/functions/v1/member/preferences`,{headers})
  expect(response.status()).toBe(200);expect(JSON.stringify(await response.json())).not.toMatch(/user_id|target_user|birthYear|onboarding|requestKey/)
  const other=await request.get(`${data.apiUrl}/functions/v1/member/preferences`,{headers:{authorization:`Bearer ${await auth(data.users[1])}`}})
  expect((await other.json()).events).toHaveLength(0)
  const started=db('select clock_timestamp();')
  db(prefix+`select pg_temp.next_people('${next}','${label}',8);
   update app_private.intake_applications set user_id='${user.id}' where id=md5('${next}1app')::uuid;
   update app_private.payment_attempts set user_id='${user.id}' where application_id=md5('${next}1app')::uuid;commit;`)
  await expect.poll(()=>db(`select count(*) from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id where ta.active and t.status='CONFIRMED' and t.slot_id=md5('${next}slot')::uuid;`),{timeout:80000,intervals:[1500,2500]}).toBe('8')
  expect(db(`select count(*) from app_private.table_assignments a join app_private.table_assignments b on b.table_id=a.table_id join app_private.dining_tables t on t.id=a.table_id where a.active and b.active and t.slot_id=md5('${next}slot')::uuid and a.user_id='${user.id}' and b.user_id='${target}';`)).toBe('0')
  expect(db(`select count(*) from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id where a.active and t.slot_id=${slot};`)).toBe('4')
  expect(Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-matching-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`))).toBeGreaterThan(0)
  await panel.screenshot({path:'../.local/person-preferences-mobile.png'})
  db(`update app_private.intake_applications set attendance_status='NO_SHOW' where user_id='${user.id}' and input->'slotIds' ? ${slot}::text;`)
  await panel.getByRole('button',{name:'참석 이력·사람 선택 새로고침',exact:true}).click();await expect(panel.getByText('아직 참석이 확인된 지난 식탁이 없어요.',{exact:true})).toBeVisible()
 }finally{
  db(`begin;delete from app_private.attendance_actions where assignment_id in(${assignments});delete from app_private.attendance_records where assignment_id in(${assignments});
   delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slots})) or aggregate_id in(${apps});delete from app_private.allocation_attempts where application_id in(${apps});
   delete from app_private.table_assignments where application_id in(${apps});delete from app_private.dining_tables where slot_id in(${slots});delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slots}));delete from app_private.match_jobs where slot_id in(${slots});
   delete from app_private.payment_attempts where application_id in(${apps});delete from app_private.intake_applications where id in(${apps});delete from app_private.intake_event_slots where id in(${slots});
   delete from app_private.member_audit where actor_id in(${users}) or (actor_id='${user.id}' and action='PERSON_PREFERENCE_SAVE');delete from app_private.member_accounts where user_id in(${users});delete from auth.users where id in(${users});commit;`)
 }
})
