import { test, expect } from '@playwright/test'
import path from 'node:path'

test('home leads to login without a service diagnostics panel', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
  await expect(page.getByText('서비스 연결 상태', { exact: true })).toHaveCount(0)
  await expect(page.getByLabel('이메일', { exact: true })).toHaveCount(0)
  await page.getByRole('link', { name: '로그인하기', exact: true }).click()
  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByLabel('이메일', { exact: true })).toBeVisible()
  for (const width of [320, 390]) {
    await page.setViewportSize({ width, height: 844 })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  }
  await page.screenshot({ path: path.resolve('../.local/auth-entry-login-mobile.png'), fullPage: true })
})

test('login branches keep email and browser history, and reset requires a session', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('이메일', { exact: true }).fill('navigation@example.test')
  await page.getByRole('link', { name: '회원가입', exact: true }).click()
  await expect(page).toHaveURL(/\/signup$/)
  await expect(page.getByLabel('이메일', { exact: true })).toHaveValue('navigation@example.test')
  await page.goBack()
  await expect(page.getByRole('heading', { name: '로그인', exact: true })).toBeVisible()
  await page.getByRole('link', { name: '아이디 찾기', exact: true }).click()
  await expect(page.getByText(/가입할 때 사용한 이메일이 로그인 아이디/)).toBeVisible()
  await page.getByRole('link', { name: '비밀번호 찾기', exact: true }).click()
  await expect(page.getByRole('button', { name: '재설정 메일 받기', exact: true })).toBeVisible()
  await page.reload()
  await expect(page.getByRole('heading', { name: '비밀번호 찾기', exact: true })).toBeVisible()
  await page.goto('/reset-password')
  await expect(page.getByText(/유효한 비밀번호 재설정 링크가 필요/)).toBeVisible()
  await expect(page.getByLabel('새 비밀번호', { exact: true })).toHaveCount(0)
})
