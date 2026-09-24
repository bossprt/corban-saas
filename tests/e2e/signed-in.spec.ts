import { expect, test } from '@playwright/test'

// Signed-in smoke tests. They run only against a local or test database whose test user is given through
// E2E_EMAIL / E2E_PASSWORD (never a production account). Without those variables the suite is skipped.
const email = process.env.E2E_EMAIL
const password = process.env.E2E_PASSWORD
const shots = process.env.E2E_SCREENSHOTS

test.skip(!email || !password, 'E2E_EMAIL and E2E_PASSWORD are not set')
// A dev server compiles each route on first visit.
test.setTimeout(120_000)

test.beforeEach(async ({ page }) => {
  await page.goto('/login')
  await page.locator('input[type="email"]').fill(email!)
  await page.locator('input[type="password"]').fill(password!)
  await page.locator('button[type="submit"]').click()
  await page.waitForURL(/\/app(\/|$)/)
})

const pages = [
  { path: '/app', name: 'dashboard' },
  { path: '/app/atencao', name: 'hoje' },
  { path: '/app/clientes', name: 'clientes' },
  { path: '/app/propostas', name: 'esteira' },
  { path: '/app/comercial', name: 'comercial' },
]

for (const { path, name } of pages) {
  test(`shell renders ${name}`, async ({ page }, info) => {
    await page.goto(path)
    await expect(page.getByRole('navigation', { name: info.project.name === 'mobile' ? 'Navegação inferior' : 'Principal' })).toBeVisible()
    await expect(page.locator('main')).toBeVisible()
    if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-${name}.png`, fullPage: true })
  })
}
