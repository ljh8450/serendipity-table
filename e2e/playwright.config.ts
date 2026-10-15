import { defineConfig } from '@playwright/test'
export default defineConfig({
  testDir: './tests',
  use: { baseURL: 'http://127.0.0.1:4173', viewport: { width: 390, height: 844 }, trace: 'retain-on-failure' },
  webServer: {
    command: 'npm --prefix ../frontend run preview',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: !process.env.CI,
  },
})
