import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import path from 'node:path'

test('operator publishes matching policy and message versions while participant is refused', async ({ page, request }) => {
 const data = JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'), 'utf8'))
 if (data.apiUrl !== 'http://127.0.0.1:54331') throw Error('Nonlocal fixture refused')
 const user = data.users[2]
 const login = async (account: typeof user) => {
  const result = await request.post(`${data.apiUrl}/auth/v1/token?grant_type=password`, { headers: { apikey: data.publishableKey }, data: { email: account.email, password: account.password } })
  expect(result.ok()).toBe(true); return (await result.json()).access_token as string
 }
 const token = await login(user)
 const headers = { authorization: `Bearer ${token}` }
 const base = `${data.apiUrl}/functions/v1/member/operations`
 const policy = await (await request.get(`${base}/policy`, { headers })).json()
 const templates = await (await request.get(`${base}/templates`, { headers })).json()
 const original = templates.templates.find((t: { kind: string }) => t.kind === 'D1')
 try {
  await page.goto('/login'); await page.getByLabel('이메일', { exact: true }).fill(user.email); await page.getByLabel('비밀번호', { exact: true }).fill(user.password); await page.getByRole('button', { name: '로그인', exact: true }).click()
  await expect(page.getByRole('region', { name: '운영 현황', exact: true }).getByText(/집계:/)).toBeVisible()
  await expect(page.getByLabel('현황 회차', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: '모집 준비', exact: true }).click()
  const panel = page.getByRole('region', { name: '매칭 규칙 설정', exact: true })
  await panel.getByLabel('최소 매칭 점수', { exact: true }).fill(String(policy.minimumScore === 100 ? 99 : policy.minimumScore + 1))
  await panel.getByRole('button', { name: '매칭 규칙 발행', exact: true }).click()
  await expect(panel.getByRole('status')).toHaveText('새 매칭 규칙을 발행했어요.')
  const edited = await (await request.get(`${base}/policy`, { headers })).json()
  expect(edited.version).not.toBe(policy.version)
  const tpanel = page.getByRole('region', { name: '자동 안내 템플릿 관리', exact: true })
  await tpanel.getByLabel('전날 리마인드 문구 (최대 500자)', { exact: true }).fill('LOCAL E2E 안내 문구 — 발송 시점의 버전을 보존해요.')
  await tpanel.getByRole('button', { name: '전날 리마인드 발행', exact: true }).click()
  await expect(tpanel.getByRole('status')).toHaveText('전날 리마인드 문구를 발행했어요.')
  await page.setViewportSize({ width: 320, height: 844 })
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  const participant = { authorization: `Bearer ${await login(data.users[0])}` }
  for (const route of ['policy', 'templates', 'overview']) expect((await request.get(`${base}/${route}`, { headers: participant })).status()).toBe(403)
 } finally {
  const current = await (await request.get(`${base}/policy`, { headers })).json()
  expect((await request.post(`${base}/policy`, { headers, data: { expectedVersion: current.version, minimumScore: policy.minimumScore, weights: policy.weights } })).ok()).toBe(true)
  const currentTemplates = await (await request.get(`${base}/templates`, { headers })).json()
  const currentTemplate = currentTemplates.templates.find((t: { kind: string }) => t.kind === 'D1')
  expect((await request.post(`${base}/templates`, { headers, data: { kind: 'D1', expectedVersion: currentTemplate.version, body: original.body } })).ok()).toBe(true)
 }
})
