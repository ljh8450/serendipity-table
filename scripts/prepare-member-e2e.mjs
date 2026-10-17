import { execSync, execFileSync } from 'node:child_process'
import { randomUUID, createHmac } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

process.chdir(fileURLToPath(new URL('..', import.meta.url)))
// Fixed command, captured output: local status includes server credentials.
const state = JSON.parse(execSync('npx --yes supabase@2.121.0 status -o json', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }))
const apiUrl = 'http://127.0.0.1:54331'
if (state.API_URL !== apiUrl) throw new Error('Refusing non-project/local fixture target')
const headers = { apikey: state.SERVICE_ROLE_KEY, Authorization: `Bearer ${state.SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' }
const fixturePath = '.local/member-e2e.json'
if (existsSync(fixturePath)) {
  const previous = JSON.parse(readFileSync(fixturePath, 'utf8').replace(/^\uFEFF/, ''))
  for (const user of previous.users) {
    if (!/^[0-9a-f-]{36}$/i.test(user.id)) throw new Error('Invalid local fixture ID')
    const lookup = await fetch(`${apiUrl}/auth/v1/admin/users/${user.id}`, { headers })
    if (lookup.status === 404) continue
    if (!lookup.ok) throw new Error('Previous fixture lookup failed')
    const existing = await lookup.json()
    if (!/^(member|signup)-[0-9a-f-]{32,36}@example\.test$/i.test(existing.email ?? '')) throw new Error('Refusing non-fixture account cleanup')
    const response = await fetch(`${apiUrl}/auth/v1/admin/users/${user.id}`, { method: 'DELETE', headers })
    if (!response.ok && response.status !== 404) throw new Error('Previous local fixture cleanup failed')
  }
}
const users = []
for (let i = 0; i < 4; i++) {
  const email = `member-${randomUUID()}@example.test`
  const password = `${randomUUID()}Aa1!`
  const response = await fetch(`${apiUrl}/auth/v1/admin/users`, {
    method: 'POST', headers, body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { role: 'operator' } }),
  })
  if (!response.ok) throw new Error('Local Auth fixture creation failed')
  const { id } = await response.json()
  users.push({ id, email, password })
}
mkdirSync('.local', { recursive: true })
const expiredParts = [
  Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url'),
  Buffer.from(JSON.stringify({ sub: users[0].id, role: 'authenticated', aud: 'authenticated', exp: 1 })).toString('base64url'),
].join('.')
const expiredToken = `${expiredParts}.${createHmac('sha256', state.JWT_SECRET).update(expiredParts).digest('base64url')}`
writeFileSync(fixturePath, JSON.stringify({ apiUrl, publishableKey: state.PUBLISHABLE_KEY, users, expiredToken }))
const seed = `update app_private.consent_documents set active=false where version like 'e2e-%';
update app_private.consent_documents set active=true where id in ('30000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002');
insert into app_private.consent_documents(id,kind,version,title,body,required,active) values
('30000000-0000-4000-8000-000000000001','privacy','local-demo-v1','로컬 테스트 전용 개인정보 동의','가상 데이터 저장 검증용 문서입니다. 실제 개인정보 수집 동의가 아닙니다.',true,true),
('30000000-0000-4000-8000-000000000002','operations','local-demo-v1','로컬 테스트 전용 운영 정책','가상 신청 흐름 검증용 문서입니다. 실제 운영 정책이 아닙니다.',true,true)
on conflict(id) do nothing;
insert into app_private.member_accounts(user_id,role) values('${users[2].id}','operator') on conflict(user_id) do update set role='operator';`
execFileSync('docker', ['exec', '-i', 'supabase_db_serendipity-table', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], { input: seed, stdio: ['pipe', 'ignore', 'pipe'] })
const slots = `insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,region_code,region_label,published) values
('50000000-0000-4000-8000-000000000001',now()+interval '5 days',now()-interval '1 day',now()+interval '4 days','hongdae','홍대/합정 · 로컬 테스트',true),
('50000000-0000-4000-8000-000000000002',now()+interval '12 days',now()-interval '1 day',now()+interval '11 days','jamsil','잠실 · 로컬 테스트',true)
on conflict(id) do update set starts_at=excluded.starts_at,opens_at=excluded.opens_at,closes_at=excluded.closes_at;`
execFileSync('docker', ['exec', '-i', 'supabase_db_serendipity-table', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], { input: slots, stdio: ['pipe', 'ignore', 'pipe'] })
writeFileSync('frontend/.env.local', `VITE_SUPABASE_URL=${apiUrl}\nVITE_SUPABASE_PUBLISHABLE_KEY=${state.PUBLISHABLE_KEY}\n`)
console.log('Local member E2E fixture prepared (4 disposable users (one server-assigned operator, one matching fixture), demo documents). No credentials printed.')
