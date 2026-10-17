import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db=(sql:string)=>execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()

test('actual Cron opens a real shared chat; lost-response retry is unique and cancellation revokes access immediately',async({page,request,browser})=>{
 test.setTimeout(125000)
 const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(data.apiUrl!=='http://127.0.0.1:54331')throw new Error('Refusing nonlocal fixture')
 const primary=data.users[3],second=data.users[1],label=`e2e-chat-${randomUUID()}`
 const slot=`md5('${label}slot')::uuid`,app=`md5('${label}primary')::uuid`
 const others=[1,2,3].map(i=>`md5('${label}${i}user')::uuid`).join(',')
 const fixtureApps=`select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text`
 const prefix=readFileSync(path.resolve('../supabase/tests/matching_permissions.sql'),'utf8').split('do $$ declare count_n')[0]
 db(prefix+`select pg_temp.match_fixture('${label}',3);
 insert into app_private.member_accounts(user_id) values('${primary.id}'),('${second.id}') on conflict do nothing;
 insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
 select md5('${label}'||x.suffix)::uuid,x.actor,gen_random_uuid(),a.input,a.identity_snapshot,a.onboarding_snapshot,a.schema_version,a.consent_snapshot,a.product_snapshot,'PAID'
 from (values('${primary.id}'::uuid,'primary'),('${second.id}'::uuid,'second')) x(actor,suffix) cross join app_private.intake_applications a where a.id=md5('${label}1app')::uuid;
 insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) select user_id,id,gen_random_uuid(),'success',9900 from app_private.intake_applications where id in(${app},md5('${label}second')::uuid);
 select app_private.matching_tick();commit;`)
 const otherContext=await browser.newContext({baseURL:'http://127.0.0.1:4173',viewport:{width:390,height:844}}),otherPage=await otherContext.newPage()
 const login=async(p:typeof page,u:{email:string;password:string})=>{await p.goto('/');await p.getByLabel('이메일',{exact:true}).fill(u.email);await p.getByLabel('비밀번호',{exact:true}).fill(u.password);await p.getByRole('button',{name:'로그인',exact:true}).click()}
 const auth=async(u:{email:string;password:string})=>{const response=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:u.email,password:u.password}});return (await response.json()).access_token as string}
 try{
  const token=await auth(primary),secondToken=await auth(second),headers={authorization:`Bearer ${token}`}
  let room=''
  await expect.poll(async()=>{const response=await request.get(`${data.apiUrl}/functions/v1/member/matching`,{headers});expect(response.status()).toBe(200);room=(await response.json()).applications.find((a:{id:string})=>a.id===db(`select ${app};`))?.table?.chat?.roomId??'';return !!room},{timeout:80000,intervals:[1500,2500]}).toBe(true)
  await login(page,primary);await page.getByRole('button',{name:'단체방 열기',exact:true}).click()
  await expect(page.getByText('식탁 단체방이 열렸어요. 장소와 준비 안내는 매칭 상태에서 확인해 주세요.',{exact:true})).toBeVisible()
  let lost=false;const keys:string[]=[]
  await page.route('**/member/chat/*/messages',async route=>{keys.push(route.request().postDataJSON().requestKey);if(!lost){lost=true;const response=await route.fetch();expect(response.status()).toBe(200);await route.abort('failed')}else await route.continue()})
  const text='<img src=x onerror=alert(1)> LOCAL CHAT'
  const input=page.getByLabel('보낼 메시지 (최대 1,000자)',{exact:true})
  await input.fill(text)
  const failed=page.waitForEvent('requestfailed',r=>r.url().endsWith('/messages'))
  await page.getByRole('button',{name:'메시지 전송',exact:true}).click();await failed
  await expect(input).toHaveValue(text)
  await page.getByRole('button',{name:'메시지 전송',exact:true}).click()
  await expect(input).toHaveValue('')
  expect(keys).toHaveLength(2);expect(keys[0]).toBe(keys[1])
  expect(db(`select count(*) from app_private.chat_messages where room_id='${room}' and kind='MEMBER';`)).toBe('1')
  await login(otherPage,second);await otherPage.getByRole('button',{name:'단체방 열기',exact:true}).click()
  await expect(otherPage.getByRole('list',{name:'대화 메시지'}).getByText(text,{exact:true})).toBeVisible()
  await expect(otherPage.getByRole('list',{name:'대화 메시지'}).locator('img')).toHaveCount(0)
  await otherPage.getByLabel('보낼 메시지 (최대 1,000자)',{exact:true}).fill('함께할 식사가 기대돼요.')
  await otherPage.getByRole('button',{name:'메시지 전송',exact:true}).click()
  await expect(page.getByText('함께할 식사가 기대돼요.',{exact:true})).toBeVisible({timeout:10000})
  const inbox=page.getByRole('region',{name:/나의 알림/})
  await page.getByRole('button',{name:'알림 새로고침',exact:true}).click()
  await expect(inbox.getByText('식탁에 새 대화가 있어요',{exact:true})).toBeVisible()
  const notices=await request.get(`${data.apiUrl}/functions/v1/member/notifications`,{headers})
  expect(notices.status()).toBe(200)
  const noticeData=await notices.json()
  expect(JSON.stringify(noticeData)).not.toContain('함께할 식사가')
  const notice=noticeData.notifications.find((n:{kind:string})=>n.kind==='CHAT_MESSAGE')
  expect((await request.post(`${data.apiUrl}/functions/v1/member/notifications/read`,{headers:{authorization:`Bearer ${secondToken}`},data:{id:notice.id}})).status()).toBe(403)
  await inbox.getByRole('button',{name:'읽음으로 표시',exact:true}).last().click()
  await expect(inbox.getByText(/· 읽음$/).first()).toBeVisible()
  await expect.poll(()=>db(`select count(*) from app_private.notification_receipts r join app_private.match_outbox o on o.id=r.event_id where o.aggregate_id in(select id from app_private.dining_tables where slot_id=${slot});`),{timeout:80000,intervals:[1500,2500]}).toBe('1')
  await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390)
  await page.screenshot({path:'test-results/chat-mobile.png',fullPage:true})
  await page.reload();await page.getByRole('button',{name:'단체방 열기',exact:true}).click()
  await expect(page.getByRole('list',{name:'대화 메시지'}).getByText(text,{exact:true})).toBeVisible()
  const outsiderToken=await auth(data.users[0])
  expect((await request.get(`${data.apiUrl}/functions/v1/member/chat/${room}`,{headers:{authorization:`Bearer ${outsiderToken}`}})).status()).toBe(403)
  expect((await request.get(`${data.apiUrl}/functions/v1/member/operations/chat`,{headers})).status()).toBe(403)
  expect((await request.post(`${data.apiUrl}/functions/v1/member/chat/tick`,{headers,data:{}})).status()).toBe(404)
  const operatorToken=await auth(data.users[2])
  const monitor=await request.get(`${data.apiUrl}/functions/v1/member/operations/chat`,{headers:{authorization:`Bearer ${operatorToken}`}})
  expect(monitor.status()).toBe(200);expect(JSON.stringify(await monitor.json())).not.toContain('LOCAL CHAT')
  const cancel=await request.post(`${data.apiUrl}/functions/v1/member/matching/resolve`,{headers,data:{applicationId:db(`select ${app};`),requestKey:randomUUID(),action:'cancel'}})
  expect(cancel.status()).toBe(200)
  expect((await request.get(`${data.apiUrl}/functions/v1/member/chat/${room}`,{headers})).status()).toBe(403)
  const canceledNotices=await request.get(`${data.apiUrl}/functions/v1/member/notifications`,{headers})
  expect((await canceledNotices.json()).notifications).toHaveLength(0)
  expect((await request.post(`${data.apiUrl}/functions/v1/member/chat/${room}/messages`,{headers,data:{requestKey:keys[0],body:text}})).status()).toBe(403)
  const remaining=await request.get(`${data.apiUrl}/functions/v1/member/chat/${room}`,{headers:{authorization:`Bearer ${secondToken}`}})
  expect(remaining.status()).toBe(200);expect((await remaining.json()).members).toHaveLength(4)
  await expect(page.getByText('현재 참여 중인 식탁의 방에만 접근할 수 있어요. 매칭 상태를 다시 확인해 주세요.',{exact:true})).toBeVisible({timeout:10000})
  await expect(page.getByRole('list',{name:'대화 메시지'})).toHaveCount(0)
 }finally{
  await otherContext.close()
  db(`begin;delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(${fixtureApps});
   delete from app_private.allocation_attempts where application_id in(${fixtureApps});delete from app_private.table_assignments where application_id in(${fixtureApps});
   delete from app_private.dining_tables where slot_id=${slot};delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
   delete from app_private.refund_attempts where application_id in(${fixtureApps});delete from app_private.payment_attempts where application_id in(${fixtureApps});delete from app_private.intake_applications where input->'slotIds' ? ${slot}::text;
   delete from app_private.intake_event_slots where id=${slot};delete from app_private.member_audit where actor_id in(${others});delete from app_private.member_accounts where user_id in(${others});delete from auth.users where id in(${others});commit;`)
 }
})
