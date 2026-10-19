import { test, expect } from '@playwright/test'
test('mobile production frontend connects to real API and database', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
  await page.getByText('서비스 연결 상태', { exact: true }).click()
  await expect(page.getByRole('status')).toHaveText('서비스에 연결되었습니다.')
  await expect(page.getByRole('button', { name: '다시 시도' })).toHaveCount(0)
})
test('failed API request offers retry and recovers', async ({ page }) => {
  await page.route('**/functions/v1/system-status', route => route.abort())
  await page.goto('/')
  await expect(page.getByRole('button', { name: '다시 시도' })).toBeVisible()
  await page.unroute('**/functions/v1/system-status')
  await page.getByRole('button', { name: '다시 시도' }).click()
  await expect(page.locator('.connection-status [role=status]')).toHaveText('서비스에 연결되었습니다.')
})
