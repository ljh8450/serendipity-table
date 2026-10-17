// Actual local scheduled posting + real FCM reception, using disposable data and a dedicated Chrome profile.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { chromium, expect } = require('../e2e/node_modules/@playwright/test');
process.chdir(path.resolve(__dirname,'..'));
const db = q => { try { return execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-At','-v','ON_ERROR_STOP=1'],{input:q,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim(); } catch { throw Error('Local content DB operation failed'); } };
(async () => {
  const data = JSON.parse(fs.readFileSync('.local/member-e2e.json','utf8').replace(/^\uFEFF/,''));
  if(data.apiUrl !== 'http://127.0.0.1:54331') throw Error('Local only');
  const primary = data.users[3],label = `content-browser-${crypto.randomUUID()}`,operator = crypto.randomUUID();
  const slot = `md5('${label}slot')::uuid`,app = `md5('${label}primary')::uuid`;
  const others = [1,2,3].map(i=>`md5('${label}${i}user')::uuid`).join(',');
  const fixtureApps = `select id from app_private.intake_applications where input->'slotIds' ? ${slot}::text`;
  const prefix = fs.readFileSync('supabase/tests/matching_permissions.sql','utf8').split('do $$ declare count_n')[0];
  const context = await chromium.launchPersistentContext('.local/content-chrome-profile',{channel:'chrome',headless:true,ignoreDefaultArgs:['--disable-background-networking','--disable-component-extensions-with-background-pages'],permissions:['notifications'],baseURL:'http://127.0.0.1:4173',viewport:{width:390,height:844}});
  let page = await context.newPage(),session,endpoint;
  const api = `${data.apiUrl}/functions/v1/member`;
  async function login() {
    await page.goto('/');await page.getByLabel('이메일',{exact:true}).fill(primary.email);await page.getByLabel('비밀번호',{exact:true}).fill(primary.password);
    const auth = page.waitForResponse(r=>r.url().includes('/auth/v1/token'));await page.getByRole('button',{name:'로그인',exact:true}).click();session = await(await auth).json();
  }
  async function get(route) { const response=await fetch(api+route,{headers:{authorization:`Bearer ${session.access_token}`}});return {status:response.status,body:await response.json()}; }
  async function waitPost(kind,noticeKind) {
    const end = Date.now()+160000;let id;
    while(Date.now()<end) {
      id = db(`select n.id from app_private.member_notifications n join app_private.dining_tables t on t.id=n.table_id join app_private.push_jobs p on p.notification_id=n.id where t.slot_id=${slot} and n.user_id='${primary.id}' and n.kind='${noticeKind}' and p.status='ACCEPTED';`);
      if(id && db(`select count(*) from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where t.slot_id=${slot} and j.kind='${kind}' and j.status='DONE';`)==='1')break;
      await new Promise(r=>setTimeout(r,1500));
    }
    if(!/^[0-9a-f-]{36}$/.test(id??''))throw Error(`Actual ${kind} posting/provider acceptance missing`);
    page = await context.newPage();await page.goto('/');
    await expect.poll(()=>page.evaluate(async id=>!!await(await caches.open('push-receipts-v1')).match('/__push_receipt/'+id),id),{timeout:15000,intervals:[1000]}).toBe(true);
    return id;
  }
  try {
    await login();const subscribed=page.waitForResponse(r=>r.url().endsWith('/member/push/subscribe'),{timeout:45000});
    await page.getByRole('button',{name:'이 기기 푸시 켜기',exact:true}).click();if((await subscribed).status()!==200)throw Error('Actual subscription failed');
    endpoint=await page.evaluate(async()=> (await(await navigator.serviceWorker.ready).pushManager.getSubscription()).endpoint);
    const started = new Date().toISOString();
    db(prefix+`select pg_temp.match_fixture('${label}',3);
     insert into app_private.member_accounts(user_id) values('${primary.id}') on conflict do nothing;
     insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
      select ${app},'${primary.id}',gen_random_uuid(),input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,'PAID' from app_private.intake_applications where id=md5('${label}1app')::uuid;
     insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values('${primary.id}',${app},gen_random_uuid(),'success',9900);
     update app_private.intake_applications set onboarding_snapshot=onboarding_snapshot||'{"mealBudgetBands":["10_20"],"allergies":"","avoidedFoods":"","interests":["film","food","travel"],"traits":["deep","calm"]}' where id in(${fixtureApps});
     insert into auth.users(id) values('${operator}');insert into app_private.member_accounts(user_id,role) values('${operator}','operator');
     select app_private.matching_tick();select app_private.chat_tick();select set_config('app.actor_id','${operator}',true);
     select app_private.operations_venue_create(jsonb_build_object('requestKey',gen_random_uuid(),'slotId',${slot},'name','LOCAL CONTENT VENUE','address','LOCAL CONTENT ADDRESS','mapUrl','https://example.test/map','reservationName','${label}','mealPriceKrw',15000,'seats',6,'rating',4.5,'reviewCount',40,'reviewUrl','https://example.test/review','verifiedAt',now()-interval '1 minute','reservationValidUntil',now()+interval '8 days','safeAllergies','[]'::jsonb,'safeAvoidedFoods','[]'::jsonb,'verificationNote','LOCAL FIXTURE','reservationConfirmed',true));
     select app_private.venue_tick();update app_private.intake_event_slots set starts_at=clock_timestamp()+interval '23 hours' where id=${slot};commit;`);
    await page.close();await waitPost('D1','EVENT_REMINDER');
    const room = db(`select r.id from app_private.chat_rooms r join app_private.dining_tables t on t.id=r.table_id where t.slot_id=${slot};`);
    const d1 = await get(`/chat/${room}`);
    if(d1.status!==200 || !d1.body.messages.some(m=>m.body.includes('다가오는 식탁 안내')) || !d1.body.messages.some(m=>m.body.includes(label)) || !d1.body.messages.some(m=>m.body.includes('취소·환불')))throw Error('D1 details missing');
    db(`begin;select pg_advisory_xact_lock(hashtextextended('content-tick',0));select pg_advisory_xact_lock(hashtextextended('matching-state',0));
     update app_private.intake_event_slots set starts_at=clock_timestamp()-interval '1 second',closes_at=least(closes_at,clock_timestamp()-interval '2 minutes'),matches_at=least(matches_at,clock_timestamp()-interval '1 minute') where id=${slot};
     update app_private.content_jobs j set scheduled_at=s.starts_at,due_at=s.starts_at from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id where j.table_id=t.id and t.slot_id=${slot} and j.kind='START';commit;`);
    await page.close();const startNotice=await waitPost('START','EVENT_CONTENT');
    const registered=await page.evaluate(async id=>(await(await navigator.serviceWorker.ready).getNotifications()).some(n=>n.tag==='table-'+id),startNotice);
    await login();await page.getByRole('button',{name:'단체방 열기',exact:true}).click();
    const messages=page.getByRole('list',{name:'대화 메시지'});
    await expect(messages.getByText(/^대화 주제 [123]:/)).toHaveCount(3);
    await expect(messages.getByText(/^선택 게임:/)).toBeVisible();
    await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390);
    await page.screenshot({path:'tmp/content-mobile.png',fullPage:true});
    const operatorAuth=await fetch(`${data.apiUrl}/auth/v1/token?grant_type=password`,{method:'POST',headers:{apikey:data.publishableKey,'content-type':'application/json'},body:JSON.stringify({email:data.users[2].email,password:data.users[2].password})});
    const operatorToken=(await operatorAuth.json()).access_token;
    const monitor=await fetch(api+'/operations/content',{headers:{authorization:`Bearer ${operatorToken}`}});
    if(monitor.status!==200 || /snapshot|topics|onboarding|reservation_name/.test(JSON.stringify(await monitor.json())))throw Error('Operator content DTO mismatch');
    if((await get('/operations/content')).status!==403)throw Error('Participant operator access');
    db(`insert into app_private.match_relations(user_low,user_high,reason) values(least('${primary.id}'::uuid,md5('${label}1user')::uuid),greatest('${primary.id}'::uuid,md5('${label}1user')::uuid),'report');`);
    if((await get(`/chat/${room}`)).status!==403)throw Error('Revoked room readable');
    const inbox=await get('/notifications');if(inbox.body.notifications.some(n=>['EVENT_CONTENT','EVENT_REMINDER','EVENT_GUIDE'].includes(n.kind)))throw Error('Revoked content notices visible');
    await expect(messages).toHaveCount(0,{timeout:10000});
    const logs=Number(db(`select count(*) from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='serendipity-content-tick' and d.status='succeeded' and d.start_time>='${started}'::timestamptz;`));
    if(logs<2)throw Error('Missing actual scheduler logs');
    const result={actualD1Cron:true,actualStartCron:true,realFCMProviderAccepted:true,d1WorkerReceived:true,startWorkerReceived:true,notificationApiSucceeded:true,browserNotificationRegistered:registered,topics:3,optionalGame:true,mobile:true,reportRevocation:true,operatorPrivateDTO:true,originalPagesClosed:true,localOnly:true};
    fs.writeFileSync('.local/content-browser-proof.json',JSON.stringify(result));console.log(JSON.stringify(result));
  } finally {
    try {
      if(endpoint&&session) {
        await fetch(api+'/push/unsubscribe',{method:'POST',headers:{authorization:`Bearer ${session.access_token}`,'content-type':'application/json'},body:JSON.stringify({endpoint})}).catch(()=>{});
        for(const p of context.pages())await p.evaluate(async()=>{const r=await navigator.serviceWorker.getRegistration('/');await(await r?.pushManager?.getSubscription())?.unsubscribe()}).catch(()=>{});
        if(!/^https:\/\/[A-Za-z0-9_.:/%?=&~-]+$/.test(endpoint))throw Error('Invalid cleanup endpoint');
        db(`delete from app_private.push_subscriptions where user_id='${primary.id}' and endpoint='${endpoint}';`);
      }
      db(`begin;select pg_advisory_xact_lock(hashtextextended('content-tick',0));select pg_advisory_xact_lock(hashtextextended('matching-state',0));
       delete from app_private.match_relations where user_low in(${others}) or user_high in(${others});
       delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id=${slot}) or aggregate_id in(${fixtureApps});
       delete from app_private.allocation_attempts where application_id in(${fixtureApps});delete from app_private.table_assignments where application_id in(${fixtureApps});delete from app_private.dining_tables where slot_id=${slot};
       delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id=${slot});delete from app_private.match_jobs where slot_id=${slot};
       delete from app_private.refund_attempts where application_id in(${fixtureApps});delete from app_private.payment_attempts where application_id in(${fixtureApps});delete from app_private.intake_applications where id in(${fixtureApps});
       delete from app_private.intake_event_slots where id=${slot};delete from app_private.member_audit where actor_id in(${others},'${operator}'::uuid);delete from app_private.member_accounts where user_id in(${others},'${operator}'::uuid);delete from auth.users where id in(${others},'${operator}'::uuid);commit;`);
    } finally {await context.close();}
  }
})().catch(e=>{console.error(e.message);process.exit(1)});
