import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import path from 'node:path'

test('push denial keeps inbox usable; private dispatcher and subscription authority remain server controlled', async ({ page, request }) => {
  const data = JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'), 'utf8'))
  if (data.apiUrl !== 'http://127.0.0.1:54331') throw new Error('Local only')
  const cdp = await page.context().newCDPSession(page)
  await cdp.send('Browser.setPermission', { permission: { name: 'notifications' }, setting: 'denied', origin: 'http://127.0.0.1:4173' })
  await page.goto('/')
  await page.getByLabel('이메일', { exact: true }).fill(data.users[1].email)
  await page.getByLabel('비밀번호', { exact: true }).fill(data.users[1].password)
  const auth = page.waitForResponse(r => r.url().includes('/auth/v1/token'))
  await page.getByRole('button', { name: '로그인', exact: true }).click()
  const token = (await (await auth).json()).access_token
  const settings = page.getByRole('region', { name: '이 기기 푸시 알림', exact: true })
  await expect(settings.getByText(/브라우저에서 알림이 차단돼 있어요/)).toBeVisible()
  await expect(settings.getByRole('button', { name: '이 기기 푸시 켜기', exact: true })).toBeDisabled()
  const refreshed = page.waitForResponse(r => r.url().endsWith('/member/notifications'))
  await page.getByRole('button', { name: '알림 새로고침', exact: true }).click()
  expect((await refreshed).status()).toBe(200)
  const headers = { authorization: `Bearer ${token}` }
  const api = `${data.apiUrl}/functions/v1/member`
  const config = await request.get(`${api}/push`, { headers })
  expect(config.status()).toBe(200)
  expect(JSON.stringify(await config.json())).not.toMatch(/endpoint|privateKey|p256dh|dispatchToken/)
  expect((await request.post(`${api}/push/subscribe`, { headers, data: { subscription: { endpoint: 'https://localhost/private', keys: { auth: 'A'.repeat(22), p256dh: 'B' + 'A'.repeat(86) } } } })).status()).toBe(422)
  expect((await request.post(`${api}/push/test`, { headers, data: { userId: 'other' } })).status()).toBe(422)
  expect((await request.get(`${api}/operations/push`, { headers })).status()).toBe(403)
  expect((await request.post(`${api}/operations/push/retry`, { headers, data: { jobId: crypto.randomUUID() } })).status()).toBe(403)
  expect((await request.post(`${data.apiUrl}/functions/v1/push-dispatch`, { headers, data: {} })).status()).toBe(401)
  await page.route('**/member/push', route => route.abort('failed'))
  await settings.getByRole('button', { name: '푸시 설정 다시 확인' }).click()
  await expect(settings.getByRole('alert')).toContainText('푸시 설정을 불러오지 못했어요.')
  await page.unroute('**/member/push')
  await settings.getByRole('button', { name: '푸시 설정 다시 확인' }).click()
  await expect(settings.getByRole('alert')).toHaveCount(0)
  await expect(page.locator('body')).toHaveJSProperty('scrollWidth', 390)
  await page.screenshot({ path: 'test-results/push-denied-mobile.png', fullPage: true })
})
