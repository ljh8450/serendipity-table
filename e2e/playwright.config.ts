import { defineConfig } from '@playwright/test'
export default defineConfig({
  // Specs share local Auth users and the global matching pool; keep fixtures isolated.
  workers: 1,
  globalSetup: './setup.ts',
  testDir: './tests',
  use: { baseURL: 'http://127.0.0.1:4173', viewport: { width: 390, height: 844 }, trace: 'retain-on-failure' },
  webServer: {
    command: 'npm --prefix ../frontend run preview',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: !process.env.CI,
  },
})
