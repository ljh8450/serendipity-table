import { test, expect } from '@playwright/test'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
const db = (sql: string) => execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim()

test('mobile explicitly stores, transfers, cancels early and retries original-transaction mock refund', async ({page,request}) => {
  const data=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8').replace(/^\uFEFF/,''))
  const user=data.users[3]
  if(data.apiUrl!=='http://127.0.0.1:54331' || !/^[0-9a-f-]{36}$/i.test(user.id))throw new Error('Refusing nonlocal fixture')
  const label=`e2e-resolution-${randomUUID()}`
  const slot=`md5('${label}slot')::uuid`, target=`md5('${label}target')::uuid`, app=`md5('${label}participant')::uuid`
  const others=[1,2].map(i=>`md5('${label}${i}user')::uuid`).join(',')
  const ids=`'${user.id}',${others}`
  const prefix=readFileSync(path.resolve('../supabase/tests/matching_permissions.sql'),'utf8').split('do $$ declare count_n')[0]
  db(prefix+`select pg_temp.match_fixture('${label}',2);
    insert into app_private.member_accounts(user_id) values('${user.id}') on conflict do nothing;
    insert into app_private.member_consents(user_id,document_id) select '${user.id}',id from app_private.consent_documents where active on conflict do nothing;
    insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
    select ${app},'${user.id}',gen_random_uuid(),input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,'PAID' from app_private.intake_applications where id=md5('${label}1app')::uuid;
    insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values('${user.id}',${app},gen_random_uuid(),'success',9900);
    insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity,refund_cutoff_at)
    values(${target},now()+interval '14 days',now()-interval '1 day',now()+interval '1 day',now()+interval '2 days','gangnam','LOCAL RESOLUTION TARGET',true,24,now()+interval '1 day');
    select app_private.matching_tick();commit;`)
  try{
    await page.goto('/#table')
    await page.getByLabel('이메일',{exact:true}).fill(user.email)
    await page.getByLabel('비밀번호',{exact:true}).fill(user.password)
    await page.getByRole('button',{name:'로그인',exact:true}).click()
    await expect(page.getByRole('heading',{name:'다른 일정 검토',exact:true})).toBeVisible()
    let card=page.locator('.previous-forms').filter({has:page.getByRole('heading',{name:'다른 일정 검토',exact:true})})
    await card.getByLabel('처리 방법',{exact:true}).selectOption('store')
    await expect(card.getByRole('button',{name:'선택한 처리 실행'})).toBeDisabled()
    await card.getByRole('checkbox',{name:'위 처리 내용과 결과를 확인했어요.'}).check()
    await card.getByRole('button',{name:'선택한 처리 실행'}).click()
    await expect(page.getByRole('heading',{name:'이용권 보관 중',exact:true})).toBeVisible()
    await page.screenshot({path:'test-results/resolution-stored-mobile.png',fullPage:true})
    await page.reload()
    card=page.locator('.previous-forms').filter({has:page.getByRole('heading',{name:'이용권 보관 중',exact:true})})
    await card.getByLabel('처리 방법',{exact:true}).selectOption('transfer')
    await card.getByLabel('이동할 일정·지역',{exact:true}).selectOption(db(`select ${target};`))
    await card.getByRole('checkbox',{name:/이동에 동의해요/}).check()
    await card.getByRole('button',{name:'선택한 처리 실행'}).click()
    await expect(page.getByRole('heading',{name:'일정 이동 완료',exact:true})).toBeVisible()
    await expect(page.getByRole('heading',{name:'매칭 대기',exact:true})).toBeVisible()
    await page.screenshot({path:'test-results/resolution-transferred-mobile.png',fullPage:true})
    expect(db(`select count(*) from app_private.payment_attempts where user_id='${user.id}';`)).toBe('1')
    card=page.locator('.previous-forms').filter({has:page.getByRole('heading',{name:'매칭 대기',exact:true})})
    await card.getByLabel('처리 방법',{exact:true}).selectOption('cancel')
    await card.getByRole('checkbox',{name:'위 처리 내용과 결과를 확인했어요.'}).check()
    await card.getByRole('button',{name:'선택한 처리 실행'}).click()
    await expect(page.getByRole('heading',{name:'신청 종료',exact:true})).toBeVisible()
    card=page.locator('.previous-forms').filter({has:page.getByRole('heading',{name:'신청 종료',exact:true})})
    await card.getByLabel('처리 방법',{exact:true}).selectOption('refund')
    await card.getByLabel('모의 환불 결과',{exact:true}).selectOption('failure')
    await card.getByRole('checkbox',{name:'위 처리 내용과 결과를 확인했어요.'}).check()
    await card.getByRole('button',{name:'선택한 처리 실행'}).click()
    await expect.poll(()=>db(`select payment_status from app_private.intake_applications where source_id=${app};`)).toBe('REFUND_FAILED')
    await page.reload()
    card=page.locator('.previous-forms').filter({has:page.getByRole('heading',{name:'신청 종료',exact:true})})
    await card.getByLabel('처리 방법',{exact:true}).selectOption('refund')
    await card.getByRole('checkbox',{name:'위 처리 내용과 결과를 확인했어요.'}).check()
    await card.getByRole('button',{name:'선택한 처리 실행'}).click()
    await expect.poll(()=>db(`select payment_status from app_private.intake_applications where source_id=${app};`)).toBe('REFUNDED')
    await expect(card.getByLabel('처리 방법',{exact:true})).toHaveCount(0)
    expect(db(`select count(*) from app_private.refund_attempts where user_id='${user.id}' and outcome='success';`)).toBe('1')
    await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390)
    await page.screenshot({path:'test-results/resolution-mobile.png',fullPage:true})
    const auth=await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`,{headers:{apikey:data.publishableKey},data:{email:user.email,password:user.password}})
    const session=await auth.json()
    const malicious=await request.post(`${data.apiUrl}/functions/v1/member/matching/resolve`,{headers:{authorization:`Bearer ${session.access_token}`},data:{applicationId:db(`select md5('${label}1app')::uuid;`),requestKey:randomUUID(),action:'store'}})
    expect(malicious.status()).toBe(403)
  }finally{
    db(`begin;
      delete from app_private.match_outbox where aggregate_id in(select id from app_private.dining_tables where slot_id in(${slot},${target})) or aggregate_id in(select id from app_private.intake_applications where user_id in(${ids}));
      delete from app_private.allocation_attempts where application_id in(select id from app_private.intake_applications where user_id in(${ids}));
      delete from app_private.table_assignments where user_id in(${ids});
      delete from app_private.dining_tables where slot_id in(${slot},${target});
      delete from app_private.match_runs where job_id in(select id from app_private.match_jobs where slot_id in(${slot},${target}));
      delete from app_private.match_jobs where slot_id in(${slot},${target});
      delete from app_private.refund_attempts where user_id in(${ids});
      delete from app_private.payment_attempts where user_id in(${ids});
      delete from app_private.intake_applications where user_id in(${ids});
      delete from app_private.member_audit where actor_id in(${others});
      delete from app_private.member_accounts where user_id in(${others});delete from auth.users where id in(${others});
      delete from app_private.intake_event_slots where id in(${slot},${target});commit;`)
  }
})
