import { defineConfig, devices } from '@playwright/test'

// Screen-level tests. Runs against a local production build on port 3100.
// Only unauthenticated paths are covered until the F0 test tenant exists in a non-production database.
const port = 3100
// PLAYWRIGHT_BASE_URL points the suite at an already running server (e.g. dev server on the local Supabase) and skips the built-in one.
const externalBaseURL = process.env.PLAYWRIGHT_BASE_URL

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
  use: {
    baseURL: externalBaseURL ?? `http://localhost:${port}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile', use: { ...devices['Pixel 7'] } },
  ],
  webServer: externalBaseURL ? undefined : {
    command: `npm run start -- -p ${port}`,
    url: `http://localhost:${port}/login`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})
