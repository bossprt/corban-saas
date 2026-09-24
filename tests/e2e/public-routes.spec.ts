import { expect, test } from '@playwright/test'

test('root redirects to login', async ({ page }) => {
  await page.goto('/')
  await expect(page).toHaveURL(/\/login$/)
})

test('login form shows email, password and submit', async ({ page }) => {
  await page.goto('/login')
  await expect(page.locator('input[type="email"]')).toBeVisible()
  await expect(page.locator('input[type="password"]')).toBeVisible()
  await expect(page.locator('button[type="submit"]')).toBeEnabled()
})

test('app area is closed to anonymous visitors', async ({ page }) => {
  await page.goto('/app')
  await expect(page).toHaveURL(/\/login/)
})

test('health endpoint reports database and auth probes', async ({ request }) => {
  const res = await request.get('/api/health')
  expect([200, 503]).toContain(res.status())
  const body = await res.json()
  expect(body).toHaveProperty('database')
  expect(body).toHaveProperty('auth')
})
