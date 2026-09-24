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
  { path: '/app/hoje', name: 'hoje' },
  { path: '/app/atencao', name: 'atencao' },
  { path: '/app/clientes', name: 'clientes' },
  { path: '/app/propostas', name: 'esteira' },
  { path: '/app/comercial', name: 'comercial' },
  { path: '/app/equipe', name: 'equipe' },
  { path: '/app/configuracao/papeis', name: 'papeis' },
]

for (const { path, name } of pages) {
  test(`shell renders ${name}`, async ({ page }, info) => {
    await page.goto(path)
    await expect(page.getByRole('navigation', { name: info.project.name === 'mobile' ? 'Navegação inferior' : 'Principal' })).toBeVisible()
    await expect(page.locator('main')).toBeVisible()
    if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-${name}.png`, fullPage: true })
  })
}

test('Ctrl+K finds a client by name and opens it', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'keyboard shortcut is a desktop feature')
  await page.goto('/app/hoje')
  await page.keyboard.press('Control+k')
  const input = page.getByPlaceholder('CPF, telefone, nome, ADE ou vendedor')
  await expect(input).toBeVisible()
  await input.fill('Maria')
  const hit = page.getByRole('option', { name: /Maria Teste Silva/ })
  await expect(hit).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-busca.png` })
  await hit.click()
  await page.waitForURL(/\/app\/clientes\//)
})

test('administrator creates a custom role from the roles screen', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const name = `Digitador ${Date.now().toString().slice(-6)}`
  await page.goto('/app/configuracao/papeis?papel=novo')
  await page.getByLabel('Nome').fill(name)
  await page.getByLabel('Enxerga os dados de').selectOption('all')
  await page.getByLabel('Ver Propostas').check()
  await page.getByLabel('Editar Esteira').check()
  await page.getByRole('button', { name: 'Salvar papel' }).click()
  await expect(page.getByRole('status')).toHaveText('Papel salvo.')
  await expect(page.getByRole('navigation', { name: 'Papéis' }).getByText(name)).toBeVisible()
  await expect(page.getByLabel('Editar Esteira')).toBeChecked()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-papel-criado.png`, fullPage: true })
})

// A seller (scope "own") sees only the clients that are his. Runs when E2E_SELLER_EMAIL is set.
test.describe('seller scope', () => {
  const sellerEmail = process.env.E2E_SELLER_EMAIL
  test.skip(!sellerEmail, 'E2E_SELLER_EMAIL is not set')
  test.use({ storageState: { cookies: [], origins: [] } })
  test('seller does not see other people clients', async ({ browser }, info) => {
    test.skip(info.project.name === 'mobile', 'one run is enough')
    const page = await (await browser.newContext()).newPage()
    await page.goto(new URL('/login', info.project.use.baseURL).toString())
    await page.locator('input[type="email"]').fill(sellerEmail!)
    await page.locator('input[type="password"]').fill(password!)
    await page.locator('button[type="submit"]').click()
    await page.waitForURL(/\/app(\/|$)/)
    await page.goto(new URL('/app/clientes', info.project.use.baseURL).toString())
    await expect(page.getByText('Maria Teste Silva')).toHaveCount(0)
    if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-vendedor-clientes.png`, fullPage: true })
  })
})
