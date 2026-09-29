import { expect, test } from '@playwright/test'
import ExcelJS from 'exceljs'

// Signed-in smoke tests. They run only against a local or test database whose test user is given through
// E2E_EMAIL / E2E_PASSWORD (never a production account). Without those variables the suite is skipped.
const email = process.env.E2E_EMAIL
const password = process.env.E2E_PASSWORD
const shots = process.env.E2E_SCREENSHOTS
// Client field of the forms (ClientPicker): search by name and pick the seed client.
const pickClient = async (page: import('@playwright/test').Page, name = 'Ana Teste Lopes') => {
  await page.getByLabel('Cliente', { exact: true }).fill(name.split(' ').slice(0, 2).join(' '))
  await page.getByRole('option', { name: new RegExp(name) }).first().click()
}

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
  { path: '/app/cadastros', name: 'cadastros' },
  { path: '/app/equipe', name: 'equipe' },
  { path: '/app/configuracao/papeis', name: 'papeis' },
  { path: '/app/metas', name: 'metas' },
  { path: '/app/propostas/nova', name: 'nova-proposta' },
  { path: '/app/cadastros/vendedores', name: 'vendedores' },
  { path: '/app/comercial/importacao-inteligente', name: 'importacao-inteligente' },
  { path: '/app/operacional', name: 'operacional' },
  { path: '/app/relatorios', name: 'relatorios' },
  { path: '/app/financeiro', name: 'financeiro' },
  { path: '/app/financeiro/conciliacao', name: 'conciliacao' },
  { path: '/app/repasse', name: 'repasse' },
  { path: '/app/configuracao/repasse', name: 'config-repasse' },
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

test('registering an existing CPF recognizes the client instead of duplicating', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  // A valid CPF unique to this run (check digits computed here).
  const base = String(Date.now()).slice(-9)
  const dv = (s: string, w: number) => { const r = s.split('').reduce((a, c, i) => a + Number(c) * (w - i), 0) % 11; return r < 2 ? 0 : 11 - r }
  const d1 = dv(base, 10), cpf = base + d1 + dv(base + d1, 11)
  await page.goto('/app/clientes?novo=1')
  await page.getByLabel('Nome completo').fill('Cliente E2E Identidade')
  await page.getByLabel('CPF').fill(cpf)
  await page.getByLabel('Telefone').fill('(68) 99911-0001')
  await page.getByRole('button', { name: 'Cadastrar cliente' }).click()
  await expect(page.getByRole('heading', { name: 'Cliente E2E Identidade' })).toBeVisible()
  await page.goto('/app/clientes?novo=1')
  await page.getByLabel('Nome completo').fill('Nome Diferente')
  await page.getByLabel('CPF').fill(cpf)
  await page.getByLabel('Telefone').fill('(68) 98822-0002')
  await page.getByRole('button', { name: 'Cadastrar cliente' }).click()
  await expect(page.getByRole('heading', { name: 'Cliente E2E Identidade' })).toBeVisible()
  await expect(page.getByText('Este CPF já era cliente da empresa')).toBeVisible()
  await expect(page.getByText('(68) 98822-0002')).toBeVisible()
  await expect(page.getByText('(68) 99911-0001')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-cliente-ficha.png`, fullPage: true })

  // Owner (validation, 27/09/2026): the lists search by CPF too, and the CPF never goes in the URL.
  const masked = `${cpf.slice(0, 3)}.${cpf.slice(3, 6)}.${cpf.slice(6, 9)}-${cpf.slice(9)}`
  await page.goto('/app/clientes')
  await page.getByLabel('Filtrar clientes').fill(masked)
  await page.getByRole('button', { name: 'Filtrar' }).click()
  await expect(page.getByRole('heading', { name: 'Cliente E2E Identidade' })).toBeVisible()
  expect(page.url()).not.toContain(cpf.slice(0, 9))
  await page.goto('/app/contratos')
  await page.getByPlaceholder('Nome, CPF ou nº do contrato').fill(cpf)
  await page.getByRole('button', { name: 'Buscar', exact: true }).click()
  await expect(page.getByText('Este cliente ainda não tem contrato.')).toBeVisible()
  expect(page.url()).toContain('cliente=')
  expect(page.url()).not.toContain(cpf.slice(0, 9))
  await expect(page.getByText(masked)).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contratos-cpf.png`, fullPage: true })
  await page.getByRole('link', { name: 'Cadastrar contrato para este cliente' }).click()
  await expect(page).toHaveURL(/\/app\/propostas\/nova\?cliente=/)
  await expect(page.getByText('Cliente E2E Identidade').first()).toBeVisible()
  await expect(page.locator('input[type=hidden][name=customer_id]')).toHaveValue(/[0-9a-f-]{36}/)
  // A CPF nobody has: offer to register the client.
  await page.goto('/app/contratos')
  await page.getByPlaceholder('Nome, CPF ou nº do contrato').fill('529.982.247-25')
  await page.getByRole('button', { name: 'Buscar', exact: true }).click()
  await expect(page.getByText('Nenhum cliente com este CPF.')).toBeVisible()
  await expect(page.getByRole('link', { name: 'Cadastrar novo cliente' })).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contratos-cpf-sem-cliente.png` })
})

test('administrator creates an API key and an external system sends a lead with it', async ({ page, request }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/configuracao/api')
  await page.getByLabel('Nome da chave').fill(`E2E ${Date.now()}`)
  await page.getByRole('button', { name: 'Criar chave' }).click()
  const key = (await page.getByTestId('new-api-key').textContent())?.trim() ?? ''
  expect(key).toMatch(/^ck_live_/)
  const ref = `e2e-ui-${Date.now()}`
  const body = { full_name: 'Lead via API', phone: `6899${String(Date.now()).slice(-7)}`, external_ref: ref, campaign: 'e2e' }
  const first = await request.post('/api/v1/leads', { headers: { authorization: `Bearer ${key}` }, data: body })
  expect(first.status()).toBe(201)
  const again = await request.post('/api/v1/leads', { headers: { authorization: `Bearer ${key}` }, data: body })
  expect(again.status()).toBe(200)
  expect((await again.json()).duplicate).toBe(true)
  const wrong = await request.post('/api/v1/leads', { headers: { authorization: 'Bearer ck_live_invalidinvalidinvalidinvalid' }, data: body })
  expect(wrong.status()).toBe(401)
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-api.png`, fullPage: true })
})

test('direct proposal runs through the pipeline to paid and counts in the goal', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const ade = `E2E-${Date.now()}`
  await page.goto('/app/propostas/nova')
  await pickClient(page)
  await page.getByLabel('Banco e tabela').selectOption({ index: 1 })
  await page.getByLabel('Valor liberado (R$)').fill('9.500,00')
  await page.getByLabel('Prazo (meses)').fill('84')
  await page.getByLabel('Já digitada no banco').check()
  await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible({ timeout: 20_000 })

  const due = new Date(Date.now() + 3 * 86_400_000).toISOString().slice(0, 10)
  await page.getByLabel('Mover para').selectOption('pending_external')
  await page.getByLabel('Observação', { exact: true }).fill('Falta comprovante de residência')
  await page.getByLabel('Prazo da pendência').fill(due)
  await page.getByRole('button', { name: 'Salvar etapa' }).click()
  await expect(page.getByText('Pendência:', { exact: false })).toBeVisible()

  await page.getByLabel('Mover para').selectOption('submitted')
  await page.getByRole('button', { name: 'Salvar etapa' }).click()
  await expect(page.getByText('Etapa atualizada.')).toBeVisible()

  await page.getByLabel('Mover para').selectOption('paid')
  await page.getByRole('button', { name: 'Salvar etapa' }).click()
  await expect(page.getByText('Escreva uma observação')).toBeVisible()
  await page.getByLabel('Mover para').selectOption('paid')
  await page.getByLabel('Observação', { exact: true }).fill('Pago no portal do Banco Teste')
  await page.getByLabel('Pago ao cliente em').fill(new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 10))
  await page.getByRole('button', { name: 'Salvar etapa' }).click()
  await expect(page.getByText('Etapa atualizada.')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-proposta-paga.png`, fullPage: true })

  await page.goto('/app/propostas?etapa=paga')
  await expect(page.getByText(ade).filter({ visible: true }).first()).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-esteira.png`, fullPage: true })
})

test('pipeline kanban and stage settings', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/propostas?visao=kanban')
  await expect(page.getByLabel('Kanban da esteira')).toBeVisible()
  await expect(page.getByRole('region', { name: 'Aguardando digitação' })).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-kanban.png`, fullPage: true })
  await page.goto('/app/configuracao/etapas')
  const name = page.getByLabel('Nome da etapa Em análise no banco')
  await name.fill('Em análise no banco')
  await page.getByRole('row').filter({ has: name }).getByRole('button', { name: 'Salvar' }).click()
  await expect(page.getByText('Etapa salva.')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-etapas.png`, fullPage: true })
})

test('the proposal commission follows the table and the seller group', async ({ page, browser }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  // Part C1: the commission comes from the table line and the seller's group (Ouro: 3% of the gross on the à vista).
  await page.goto('/app/propostas/nova')
  await pickClient(page)
  await page.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('120')
  await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible({ timeout: 20_000 })

  // Born calculated (ADR-0040): no click needed.
  const upfront = page.getByRole('row', { name: /^À vista/ })
  await expect(upfront).toContainText('R$ 600,00')
  await expect(upfront).toContainText('R$ 300,00')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-comissao.png`, fullPage: true })

  // ADR-0031: the seller of the proposal sees only their own share, never what the company receives or the percentages.
  const sellerEmail = process.env.E2E_SELLER_EMAIL
  if (!sellerEmail) return
  const proposalUrl = page.url().split('?')[0]
  const seller = await (await browser.newContext({ storageState: { cookies: [], origins: [] } })).newPage()
  await seller.goto(new URL('/login', info.project.use.baseURL).toString())
  await seller.locator('input[type="email"]').fill(sellerEmail)
  await seller.locator('input[type="password"]').fill(password!)
  await seller.locator('button[type="submit"]').click()
  await seller.waitForURL(/\/app(\/|$)/)
  await seller.goto(proposalUrl)
  const sellerRow = seller.getByRole('row', { name: /^À vista/ })
  await expect(sellerRow).toContainText('R$ 300,00')
  await expect(sellerRow).not.toContainText('R$ 600,00')
  await expect(seller.getByText('Você vê apenas a sua parte (Vendedor).')).toBeVisible()
  await expect(seller.getByText(/imposto 6%/)).toHaveCount(0)
  await expect(seller.getByText('Recebido do banco', { exact: false })).toHaveCount(0)
  if (shots) await seller.screenshot({ path: `${shots}/${info.project.name}-comissao-vendedor.png`, fullPage: true })
})

test('finance imports a bank report, resolves the lines and confirms the receipt', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const ade = `E2E-REC-${Date.now()}`

  await page.goto('/app/propostas/nova')
  await pickClient(page)
  await page.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('120')
  await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
  await page.getByLabel('Já digitada no banco').check()
  await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible({ timeout: 20_000 })
  // Born calculated (ADR-0040): no click needed.
  const proposalUrl = page.url().split('?')[0]

  // The bank report: the contract above (exact 600,00), a contract of another company, a title block.
  const csv = `Relatório de comissão - Banco Teste\n\nContrato;Cliente;Valor comissão;Pago em\n${ade};Cliente;600,00;10/09/2026\nOUTRA-${ade};Outro;50,00;10/09/2026\n`
  await page.goto('/app/financeiro/importar')
  await page.getByLabel('Fonte pagadora').selectOption({ label: 'Banco Teste · banco' })
  await page.getByLabel('Tipo do relatório').selectOption('upfront')
  await page.getByLabel(/Total do relatório/).fill('650,00')
  await page.getByLabel(/Arquivo/).setInputFiles({ name: `avista-${ade}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf-8') })
  await page.getByRole('button', { name: 'Ler colunas do arquivo' }).click()
  await page.getByLabel(/Contrato \(ADE/).selectOption('Contrato')
  await page.getByLabel(/Valor da comissão/).selectOption('Valor comissão')
  await page.getByLabel(/Data do pagamento/).selectOption('Pago em')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-recebimento-importar.png`, fullPage: true })
  await page.getByRole('button', { name: 'Importar para conferência' }).click()
  await expect(page.getByText('Relatório importado.')).toBeVisible({ timeout: 20_000 })

  const mine = page.getByRole('row').filter({ hasText: ade }).filter({ hasNotText: 'OUTRA' })
  await expect(mine).toContainText('Confere')
  await expect(mine).toContainText('R$ 600,00')
  const other = page.getByRole('row').filter({ hasText: `OUTRA-${ade}` })
  await expect(other).toContainText('Não encontrado')
  await expect(page.getByRole('button', { name: 'Confirmar e lançar recebimentos' })).toBeDisabled()
  await other.getByPlaceholder('Motivo').fill('Contrato de outra empresa')
  await other.getByRole('button', { name: 'Ignorar' }).click()
  await expect(page.getByText('Linha ignorada.')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-recebimento-conferencia.png`, fullPage: true })
  await page.getByRole('button', { name: 'Confirmar e lançar recebimentos' }).click()
  await expect(page.getByText('Relatório confirmado.')).toBeVisible()

  await page.goto(proposalUrl)
  await expect(page.getByText(/Recebido do banco: à vista R\$\s600,00/)).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-recebimento-proposta.png`, fullPage: true })
  await page.goto('/app/financeiro')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-financeiro.png`, fullPage: true })
})

// Payout with two pairs of eyes: the administrator enters and closes, a finance user approves. Runs when E2E_FINANCE_EMAIL is set.
test.describe('payout', () => {
  const financeEmail = process.env.E2E_FINANCE_EMAIL
  test.skip(!financeEmail, 'E2E_FINANCE_EMAIL is not set')
  test('bonus and statement need a second person; the statement is paid with a receipt', async ({ page, browser }, info) => {
    test.skip(info.project.name === 'mobile', 'one run is enough')
    const finance = await (await browser.newContext()).newPage()
    await finance.goto(new URL('/login', info.project.use.baseURL).toString())
    await finance.locator('input[type="email"]').fill(financeEmail!)
    await finance.locator('input[type="password"]').fill(password!)
    await finance.locator('button[type="submit"]').click()
    await finance.waitForURL(/\/app(\/|$)/)

    // The administrator opens (or finds) the seller account and enters a bonus.
    await page.goto('/app/repasse')
    await page.getByLabel('Abrir conta de').selectOption({ label: 'Vendedor Teste' })
    await page.getByRole('button', { name: 'Abrir', exact: true }).click()
    await expect(page.getByText('Conta aberta.')).toBeVisible({ timeout: 30_000 })
    const accountUrl = page.url().split('?')[0]
    const note = `Bônus E2E ${Date.now()}`
    await page.getByLabel('Tipo').selectOption('bonus')
    await page.getByLabel('Valor (R$)').last().fill('150,00')
    await page.getByLabel('Descrição').fill(note)
    await page.getByRole('button', { name: 'Lançar' }).click()
    await expect(page.getByText('Lançamento registrado.')).toBeVisible()
    const row = page.getByRole('row').filter({ hasText: note })
    await expect(row).toContainText('Aguarda aprovação')
    await row.getByRole('button', { name: 'Aprovar' }).click()
    await expect(page.getByText('Quem lançou (ou o dono da conta) não pode aprovar.')).toBeVisible()

    // Finance approves it.
    await finance.goto(accountUrl)
    await finance.getByRole('row').filter({ hasText: note }).getByRole('button', { name: 'Aprovar' }).click()
    await expect(finance.getByText('Decisão registrada.')).toBeVisible()
    await expect(finance.getByRole('row').filter({ hasText: note })).toContainText('Aprovado')

    // The administrator closes the period; finance approves the seller statement; the administrator pays it.
    await page.goto('/app/repasse')
    await page.getByRole('button', { name: 'Fechar período' }).click()
    await expect(page.getByText('Período fechado.')).toBeVisible()
    await finance.goto(accountUrl)
    await finance.getByRole('row').filter({ hasText: 'Aguarda aprovação' }).filter({ hasText: 'Fechamento' }).getByRole('button', { name: 'Aprovar' }).click()
    await expect(finance.getByText('Decisão registrada.')).toBeVisible()
    await page.goto(accountUrl)
    const statement = page.getByRole('row').filter({ hasText: 'Aprovado, a pagar' })
    await statement.getByPlaceholder('Comprovante (PIX, TED)').fill('PIX E2E')
    await statement.getByRole('button', { name: 'Marcar pago' }).click()
    await expect(page.getByText('Pagamento registrado na conta.')).toBeVisible()
    await expect(page.getByRole('row').filter({ hasText: 'PIX E2E' }).first()).toContainText('Pago')
    if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-repasse-conta.png`, fullPage: true })
    await page.goto('/app/repasse')
    if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-repasse.png`, fullPage: true })
  })
})

// F7 broker portal: the broker sends proposals (one validated, one refused), attaches a document, and sees the outcome.
test.describe('broker portal', () => {
  const brokerEmail = process.env.E2E_BROKER_EMAIL
  test.skip(!brokerEmail, 'E2E_BROKER_EMAIL is not set')
  test('broker sends, the team validates or refuses with a reason, the broker sees it', async ({ page, browser }, info) => {
    test.skip(info.project.name === 'mobile', 'one run is enough')
    const base = String(Date.now()).slice(-9)
    const dv = (s: string, w: number) => { const r = s.split('').reduce((a, c, i) => a + Number(c) * (w - i), 0) % 11; return r < 2 ? 0 : 11 - r }
    const cpfOf = (b: string) => { const d1 = dv(b, 10); return b + d1 + dv(b + d1, 11) }
    const okName = `Portal Validar ${base}`
    const noName = `Portal Recusar ${base}`

    const broker = await (await browser.newContext({ storageState: { cookies: [], origins: [] } })).newPage()
    await broker.goto(new URL('/login', info.project.use.baseURL).toString())
    await broker.locator('input[type="email"]').fill(brokerEmail!)
    await broker.locator('input[type="password"]').fill(password!)
    await broker.locator('button[type="submit"]').click()
    await broker.waitForURL(/\/app\/portal/)
    await expect(broker.getByRole('navigation', { name: 'Principal' }).getByText('Nova proposta')).toBeVisible()
    await expect(broker.getByRole('navigation', { name: 'Principal' }).getByText('Esteira')).toHaveCount(0)

    for (const [name, cpf] of [[okName, cpfOf(base)], [noName, cpfOf(String(Number(base) + 1).padStart(9, '0'))]]) {
      await broker.getByRole('link', { name: 'Enviar nova proposta' }).click()
      await broker.getByLabel('Nome completo').fill(name)
      await broker.getByLabel('CPF').fill(cpf)
      await broker.getByLabel('Telefone').fill('(68) 99955-0001')
      await broker.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
      await broker.getByLabel('Valor solicitado (R$)').fill('10.000,00')
      await broker.getByLabel('Prazo (meses)').fill('120')
      await broker.getByRole('button', { name: 'Enviar para validação' }).click()
      await expect(broker.getByText('Proposta enviada. Ela aguarda a validação da empresa.')).toBeVisible()
      await expect(broker.getByText('Aguardando validação').first()).toBeVisible()
      if (name === okName) {
        await broker.getByLabel('Documento').fill('RG')
        await broker.getByLabel(/Arquivo/).setInputFiles({ name: 'rg.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n% e2e broker document\n%%EOF\n') })
        await broker.getByRole('button', { name: 'Anexar' }).click()
        await expect(broker.getByText('Documento anexado à proposta.')).toBeVisible({ timeout: 30_000 })
        if (shots) await broker.screenshot({ path: `${shots}/${info.project.name}-portal-proposta.png`, fullPage: true })
      }
      await broker.getByRole('link', { name: 'Minhas propostas' }).click()
    }

    // The team (admin) validates one and refuses the other with a reason.
    await page.goto('/app/propostas/validacao')
    const okCard = page.locator('section').filter({ hasText: okName }).last()
    await expect(okCard.getByRole('link', { name: 'RG' })).toBeVisible()
    if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-portal-validacao.png`, fullPage: true })
    await okCard.getByRole('button', { name: 'Validar' }).click()
    await expect(page.getByText('Proposta validada e colocada na esteira.')).toBeVisible()
    const noCard = page.locator('section').filter({ hasText: noName }).last()
    await noCard.getByLabel('Motivo da recusa').fill('Documento ilegível, envie de novo')
    await noCard.getByRole('button', { name: 'Recusar' }).click()
    await expect(page.getByText('Proposta recusada. O corretor verá o motivo.')).toBeVisible()

    await broker.goto(new URL('/app/portal', info.project.use.baseURL).toString())
    await expect(broker.getByRole('link', { name: new RegExp(noName) })).toContainText('Motivo: Documento ilegível, envie de novo')
    await expect(broker.getByRole('link', { name: new RegExp(okName) })).not.toContainText('Aguardando validação')
    if (shots) await broker.screenshot({ path: `${shots}/${info.project.name}-portal-inicio.png`, fullPage: true })
  })
})

// ADR-0033: the client page is the registration form, locked until "Editar cadastro": identity, personal data, a registration with a vaulted
// password, bank accounts; the old phone stays in the history; an account can be removed.
test('client profile: the page is the form, locked until Editar cadastro', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const base = String(Date.now() + 7).slice(-9)
  const dv = (s: string, w: number) => { const r = s.split('').reduce((a, c, i) => a + Number(c) * (w - i), 0) % 11; return r < 2 ? 0 : 11 - r }
  const d1 = dv(base, 10), cpf = base + d1 + dv(base + d1, 11)
  const name = `Cliente Ficha ${base}`
  await page.goto('/app/clientes?novo=1')
  const create = page.locator('form').filter({ hasText: '1. Identificação' })
  await create.getByLabel('Nome completo').fill(`${name} Errado`)
  await create.getByLabel('CPF').fill(cpf)
  await create.getByLabel('Telefone').fill('(68) 99911-2233')
  await create.getByLabel('Data de nascimento').fill('1980-05-17')
  await create.getByRole('button', { name: 'Cadastrar cliente' }).click()
  await expect(page.getByRole('heading', { name: `${name} Errado` })).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText('Cadastro incompleto')).toBeVisible()
  await expect(page.locator('input[name="birth_date"]')).toHaveValue('1980-05-17')
  await expect(page.getByLabel('Nome completo')).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Salvar alterações' })).toHaveCount(0)

  await page.getByRole('button', { name: 'Editar cadastro' }).click()
  const edit = page.locator('form').filter({ hasText: '1. Identificação' })
  await expect(edit.getByLabel('Nome completo')).toHaveValue(`${name} Errado`, { timeout: 30_000 })
  await edit.getByLabel('Nome completo').fill(name)
  await edit.getByLabel('Telefone').fill('(68) 98877-6655')
  await edit.getByLabel('Usar o mesmo número no WhatsApp').check()
  await edit.getByLabel('Nome da mãe').fill('Maria da Silva')
  await edit.getByLabel('Nome do pai').fill('José da Silva')
  await edit.getByLabel('RG', { exact: true }).fill('123456')
  await edit.getByLabel('Órgão expedidor').fill('SSP')
  await edit.getByLabel('UF do RG').selectOption('AC')
  await edit.getByLabel('Data de emissão').fill('2000-01-10')
  await edit.getByLabel('Sexo').selectOption('F')
  await edit.getByLabel('Estado civil').selectOption('married')
  await edit.getByLabel('Naturalidade (cidade)').fill('Rio Branco')
  await edit.getByLabel('UF de nascimento').selectOption('AC')
  const reg = edit.locator('[data-row="registration"]').nth(0)
  await reg.getByLabel('Convênio').selectOption({ label: 'INSS Teste' })
  await reg.getByLabel('Órgão', { exact: true }).fill('Secretaria de Educação')
  await reg.getByLabel('Matrícula').fill(`MAT-${base}`)
  await reg.getByLabel('Margem (R$)').fill('812,45')
  await reg.getByLabel('ID / login').fill('login.cliente')
  await reg.getByLabel('Senha').fill('Senha#E2E123')
  const acc = edit.locator('[data-row="account"]').nth(0)
  await acc.getByLabel('Código do banco').fill('001')
  await acc.getByLabel('Banco', { exact: true }).fill('Banco do Brasil')
  await acc.getByLabel('Agência').fill('1234')
  await acc.getByLabel('Conta', { exact: true }).fill('567890')
  await acc.getByLabel('Tipo').selectOption('salary')
  await edit.getByRole('button', { name: 'Adicionar outra conta' }).click()
  const acc2 = edit.locator('[data-row="account"]').nth(1)
  await acc2.getByLabel('Código do banco').fill('104')
  await acc2.getByLabel('Banco', { exact: true }).fill('Caixa')
  await acc2.getByLabel('Agência').fill('0001')
  await acc2.getByLabel('Conta', { exact: true }).fill('445566')
  await edit.getByRole('button', { name: 'Salvar alterações' }).click()
  await expect(page.getByText('Cadastro atualizado.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByRole('heading', { name })).toBeVisible()
  await expect(page.getByLabel('Nome completo')).toBeDisabled()
  await expect(page.getByLabel('Nome da mãe')).toHaveValue('Maria da Silva')
  await expect(page.getByLabel('Margem (R$)')).toHaveValue('812,45')
  await expect(page.getByText('Senha#E2E123')).toHaveCount(0)
  await page.getByRole('button', { name: 'Mostrar senha' }).click()
  await expect(page.getByText('Senha#E2E123')).toBeVisible()
  await expect(page.getByText('(68) 99911-2233')).toBeVisible()
  await expect(page.locator('input[name="bank_name"][value="Caixa"]')).toHaveCount(1)
  await expect(page.getByText('Cadastro incompleto')).toHaveCount(0)
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-cliente-ficha-completa.png`, fullPage: true })

  // Edit again: the form comes prefilled; change the margin and remove the second account.
  await page.getByRole('button', { name: 'Editar cadastro' }).click()
  const again = page.locator('form').filter({ hasText: '1. Identificação' })
  await expect(again.locator('[data-row="registration"]').nth(0).getByLabel('Matrícula')).toHaveValue(`MAT-${base}`, { timeout: 30_000 })
  await again.locator('[data-row="registration"]').nth(0).getByLabel('Margem (R$)').fill('900,00')
  await again.locator('[data-row="account"]').filter({ has: page.locator('input[value="Caixa"]') }).getByRole('button', { name: 'Remover' }).click()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-cliente-editar.png`, fullPage: true })
  await again.getByRole('button', { name: 'Salvar alterações' }).click()
  await expect(page.getByText('Cadastro atualizado.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByLabel('Margem (R$)')).toHaveValue('900,00')
  await expect(page.locator('input[name="bank_name"][value="Caixa"]')).toHaveCount(0)
})

// Single registration form (owner decision): everything at once; the same CPF again only fills what was empty.
test('single client form: complete registration at once; existing CPF fills only blanks', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const base = String(Date.now() + 11).slice(-9)
  const dv = (s: string, w: number) => { const r = s.split('').reduce((a, c, i) => a + Number(c) * (w - i), 0) % 11; return r < 2 ? 0 : 11 - r }
  const d1 = dv(base, 10), cpf = base + d1 + dv(base + d1, 11)
  const name = `Cliente Unico ${base}`
  await page.goto('/app/clientes?novo=1')
  const form = page.locator('form').filter({ hasText: '1. Identificação' })
  await form.getByLabel('Nome completo').fill(name)
  await form.getByLabel('CPF').fill(cpf)
  await form.getByLabel('Telefone').fill('(68) 99922-3344')
  await form.getByLabel('Usar o mesmo número no WhatsApp').check()
  await form.getByLabel('Data de nascimento').fill('1975-03-02')
  await form.getByLabel('Nome da mãe').fill('Ana Mãe Única')
  await form.getByLabel('RG', { exact: true }).fill('998877')
  await form.getByLabel('Órgão expedidor').fill('SESP')
  await form.getByLabel('UF do RG').selectOption('AC')
  await form.getByLabel('Estado civil').selectOption('single')
  await form.getByLabel('Código do banco').fill('104')
  await form.getByLabel('Banco', { exact: true }).fill('Caixa')
  await form.getByLabel('Agência').fill('0001')
  await form.getByLabel('Conta', { exact: true }).fill('445566')
  await form.getByLabel('Convênio').selectOption({ label: 'INSS Teste' })
  await form.getByLabel('Órgão', { exact: true }).fill('Secretaria de Saúde')
  await form.getByLabel('Matrícula').fill(`UNI-${base}`)
  await form.getByLabel('Margem (R$)').fill('350,00')
  await form.getByLabel('Senha').fill('SenhaUnica#1')
  // A second registration and a second account (marked as the primary one) in the same form.
  await form.getByRole('button', { name: 'Adicionar outra matrícula' }).click()
  const reg2 = form.locator('[data-row="registration"]').nth(1)
  await reg2.getByLabel('Convênio').selectOption({ label: 'INSS Teste' })
  await reg2.getByLabel('Órgão', { exact: true }).fill('Secretaria de Educação')
  await reg2.getByLabel('Matrícula').fill(`DOIS-${base}`)
  await reg2.getByLabel('Margem (R$)').fill('120,50')
  await form.getByRole('button', { name: 'Adicionar outra conta' }).click()
  const acc2 = form.locator('[data-row="account"]').nth(1)
  await acc2.getByLabel('Código do banco').fill('001')
  await acc2.getByLabel('Banco', { exact: true }).fill('Banco do Brasil')
  await acc2.getByLabel('Agência').fill('1234')
  await acc2.getByLabel('Conta', { exact: true }).fill('778899')
  await acc2.getByLabel('Principal').check()
  await form.getByRole('button', { name: 'Cadastrar cliente' }).click()
  await expect(page.getByRole('heading', { name })).toBeVisible({ timeout: 30_000 })
  // The client page is the locked registration form: check the saved values in its fields.
  const saved = page.locator('form').filter({ hasText: '1. Identificação' })
  await expect(saved.getByLabel('Nome da mãe')).toHaveValue('Ana Mãe Única')
  await expect(saved.getByLabel('RG', { exact: true })).toHaveValue('998877')
  await expect(saved.getByLabel('Órgão expedidor')).toHaveValue('SESP')
  await expect(saved.getByLabel('UF do RG')).toHaveValue('AC')
  const regs = saved.locator('[data-row="registration"]')
  await expect(regs).toHaveCount(2)
  await expect(saved.locator(`input[name="registration_number"][value="UNI-${base}"]`)).toHaveCount(1)
  await expect(saved.locator(`input[name="registration_number"][value="DOIS-${base}"]`)).toHaveCount(1)
  await expect(saved.locator('input[name="margin_amount"][value="350,00"]')).toHaveCount(1)
  await expect(saved.locator('input[name="margin_amount"][value="120,50"]')).toHaveCount(1)
  const account = (bank: string) => saved.locator('[data-row="account"]').filter({ has: page.locator(`input[name="bank_name"][value="${bank}"]`) })
  await expect(account('Banco do Brasil').getByLabel('Principal')).toBeChecked()
  await expect(account('Caixa').getByLabel('Principal')).not.toBeChecked()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-cadastro-unico.png`, fullPage: true })

  // Same CPF again with a different mother's name and a new father: the old value stays, the blank is filled.
  await page.goto('/app/clientes?novo=1')
  await form.getByLabel('Nome completo').fill('Outro Nome')
  await form.getByLabel('CPF').fill(cpf)
  await form.getByLabel('Nome da mãe').fill('Nome Diferente')
  await form.getByLabel('Nome do pai').fill('Pai Preenchido Depois')
  await form.getByRole('button', { name: 'Cadastrar cliente' }).click()
  await expect(page.getByRole('heading', { name })).toBeVisible({ timeout: 30_000 })
  await expect(saved.getByLabel('Nome da mãe')).toHaveValue('Ana Mãe Única')
  await expect(saved.getByLabel('Nome do pai')).toHaveValue('Pai Preenchido Depois')
})

// Seller groups (owner decision 25/09/2026): the group is the payout rule, per commission type; edits are new versions;
// own production has no payout column; a seller picks one group.
test('seller group: payout rule per commission type, versioned, own production', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const name = `Grupo E2E ${String(Date.now()).slice(-7)}`
  await page.goto('/app/comercial/grupos/novo')
  const form = page.locator('form').filter({ hasText: 'Repasse por tipo de comissão' })
  await form.getByLabel('Nome do grupo').fill(name)
  const row = (type: string) => form.locator('[data-row="component"]').filter({ has: page.getByText(type, { exact: true }) })
  await row('Diferido').getByLabel('Quantos % serão distribuídos').fill('0')
  await row('Bônus').getByLabel('Coluna de referência').selectOption('company')
  await row('Bônus').getByLabel('Quantos % serão distribuídos').fill('65,5')
  await form.locator('fieldset').filter({ hasText: 'Supervisor' }).last().getByLabel('Percentual (%)').fill('5')
  const manager = form.locator('fieldset').filter({ hasText: 'Gerente comercial' }).last()
  await manager.getByLabel('Sobre a produção total').check()
  await manager.getByLabel('Percentual (%)').fill('1,5')
  await form.getByRole('button', { name: 'Cadastrar grupo' }).click()
  await expect(page.getByText('Grupo de vendedores salvo.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByRole('heading', { name })).toBeVisible()
  await expect(page.getByText('Regra configurada')).toBeVisible()
  await expect(page.getByLabel('Nome do grupo')).toBeDisabled()
  await expect(row('Bônus').getByLabel('Quantos % serão distribuídos')).toHaveValue('65,50')
  await expect(row('Diferido').getByLabel('Quantos % serão distribuídos')).toHaveValue('0,00')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-grupo-vendedores.png`, fullPage: true })

  await page.getByRole('button', { name: 'Editar grupo' }).click()
  await page.locator('fieldset').filter({ hasText: 'Gerente comercial' }).last().getByLabel('Percentual (%)').fill('2')
  await page.getByRole('button', { name: 'Salvar grupo' }).click()
  await expect(page.getByText('Versão 2 de 2')).toBeVisible({ timeout: 30_000 })

  await page.getByRole('button', { name: 'Editar grupo' }).click()
  await page.getByLabel('Quantos % serão distribuídos').first().fill('100,5')
  await page.getByRole('button', { name: 'Salvar grupo' }).click()
  await expect(page.getByText('Confira os percentuais')).toBeVisible({ timeout: 30_000 })

  await page.goto('/app/comercial/grupos/novo')
  await page.getByLabel('Nome do grupo').fill(`${name} Própria`)
  await page.getByLabel(/Produção própria/).check()
  await expect(page.locator('[data-row="component"]')).toHaveCount(0)
  await page.getByRole('button', { name: 'Cadastrar grupo' }).click()
  await expect(page.getByText('Produção própria').first()).toBeVisible({ timeout: 30_000 })

  await page.goto('/app/cadastros/vendedores/novo')
  await expect(page.getByLabel('Grupo').first().locator('option', { hasText: name }).first()).toHaveCount(1)
  await expect(page.getByText('Grupo de Vendedor', { exact: true })).toHaveCount(0)
})

// Cadastros (owner decision 25/09/2026): every registration under one menu item, reachable by clicking only.
test('menu Cadastros: every registration reachable by clicking; old Comercial page lands there', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'side menu is desktop; the phone uses the search')
  await page.goto('/app/hoje')
  const menu = page.getByRole('navigation', { name: 'Principal' })
  await expect(menu.getByRole('link', { name: 'Comercial' })).toHaveCount(0)
  await menu.getByRole('link', { name: 'Cadastros' }).click()
  await expect(page.getByRole('heading', { name: 'Cadastros' })).toBeVisible({ timeout: 30_000 })
  for (const item of ['Bancos', 'Convênios', 'Promotoras parceiras', 'Tipos de contrato', 'Tabelas', 'Grupos de vendedores', 'Vendedores', 'Fatores', 'Equipe']) {
    await expect(menu.getByRole('link', { name: item, exact: true })).toBeVisible()
  }
  await menu.getByRole('link', { name: 'Vendedores', exact: true }).click()
  await expect(page.getByRole('link', { name: 'Novo vendedor' })).toBeVisible({ timeout: 30_000 })
  await expect(menu.getByRole('link', { name: 'Vendedores', exact: true })).toHaveAttribute('aria-current', 'page')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-menu-cadastros.png`, fullPage: true })
  await page.goto('/app/comercial')
  await expect(page).toHaveURL(/\/app\/cadastros$/, { timeout: 30_000 })
  await page.goto('/app/configuracao')
  await expect(page.getByText('Quem acessa a empresa, convites e papel de cada pessoa.')).toHaveCount(0)
})

// Seller file (owner decision 25/09/2026): automatic code, required contact, PIX and TED accounts with a payee, contacts;
// the page is the form, locked until "Editar cadastro"; a removed account leaves the file.
test('seller file: full registration with payment accounts, edited in the same form', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const base = String(Date.now()).slice(-9)
  const dv = (s: string, w: number) => { const r = s.split('').reduce((a, c, i) => a + Number(c) * (w - i), 0) % 11; return r < 2 ? 0 : 11 - r }
  const d1 = dv(base, 10), cpf = base + d1 + dv(base + d1, 11)
  const name = `Vendedor Ficha ${base}`
  await page.goto('/app/cadastros/vendedores')
  await page.getByRole('link', { name: 'Novo vendedor' }).click()
  const form = page.locator('form').filter({ hasText: '1. Dados básicos' })
  await form.getByLabel(/Nome \/ razão social/).fill(name)
  await form.locator('input[name="tax_id"]').fill(cpf)
  await form.locator('select[name="seller_category"]').selectOption('pf')
  await form.locator('select[name="commission_group_id"]').selectOption({ label: 'Ouro' })
  await form.locator('input[name="mobile"]').fill('(68) 99955-4433')
  await form.getByLabel('Usar o celular no WhatsApp').check()
  await form.locator('input[name="email"]').fill(`vendedor.${base}@example.com`)
  await form.getByLabel('Nome da mãe').fill('Mãe do Vendedor')
  const acc = form.locator('[data-row="seller-account"]').nth(0)
  await acc.getByLabel('Tipo de chave PIX').selectOption('email')
  await acc.getByLabel('Chave PIX', { exact: true }).fill(`pix.${base}@example.com`)
  await form.getByRole('button', { name: 'Adicionar outra conta' }).click()
  const ted = form.locator('[data-row="seller-account"]').nth(1)
  await ted.getByLabel('Forma de pagamento').selectOption('ted')
  await ted.getByLabel('Código do banco').fill('104')
  await ted.getByLabel('Banco', { exact: true }).fill('Caixa')
  await ted.getByLabel('Agência').fill('0001')
  await ted.getByLabel('Conta', { exact: true }).fill('445566')
  await ted.getByLabel('O dinheiro vai para outra pessoa ou empresa (favorecido)').check()
  await ted.getByLabel('Nome do favorecido').fill('Empresa do Vendedor Ltda')
  await ted.getByLabel('CPF/CNPJ do favorecido').fill('11.222.333/0001-81')
  await ted.getByLabel('Principal').check()
  await form.getByRole('button', { name: 'Adicionar contato' }).click()
  await form.locator('[data-row="seller-contact"]').nth(0).getByLabel('Nome').fill('Sócio do Vendedor')
  await form.getByRole('button', { name: 'Cadastrar vendedor' }).click()
  await expect(page.getByText('Vendedor cadastrado.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByRole('heading', { name })).toBeVisible()
  await expect(page.getByText(/^Código \d{3,}$/)).toBeVisible()
  await expect(page.getByLabel(/Nome \/ razão social/)).toBeDisabled()
  const saved = page.locator('form').filter({ hasText: '1. Dados básicos' })
  await expect(saved.locator('[data-row="seller-account"]')).toHaveCount(2)
  await expect(saved.locator('[data-row="seller-account"]').nth(0).getByLabel('Nome do favorecido')).toHaveValue('Empresa do Vendedor Ltda')
  await expect(saved.locator('[data-row="seller-account"]').nth(0).getByLabel('Principal')).toBeChecked()
  await expect(saved.locator('input[name="whatsapp"]')).toHaveValue('(68) 99955-4433')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-vendedor-ficha.png`, fullPage: true })

  // Required fields are enforced by the database too: a bad PIX key is refused with a clear message.
  await page.getByRole('button', { name: 'Editar cadastro' }).click()
  await saved.locator('[data-row="seller-account"]').nth(1).getByLabel('Chave PIX', { exact: true }).fill('nao-e-email')
  await saved.getByRole('button', { name: 'Salvar alterações' }).click()
  await expect(page.getByText('Chave PIX inválida')).toBeVisible({ timeout: 30_000 })

  await page.getByRole('button', { name: 'Editar cadastro' }).click()
  await saved.locator('[data-row="seller-account"]').nth(1).getByRole('button', { name: 'Remover' }).click()
  await saved.getByRole('button', { name: 'Salvar alterações' }).click()
  await expect(page.getByText('Cadastro do vendedor atualizado.')).toBeVisible({ timeout: 30_000 })
  await expect(saved.locator('[data-row="seller-account"]')).toHaveCount(1)
  await page.goto('/app/cadastros/vendedores')
  await expect(page.getByRole('link', { name: new RegExp(name) })).toBeVisible()
})

// Part B (owner decision 25/09/2026): a 2tech-layout file is imported with its "Repasse N" columns mapped to seller
// groups; the table shows the company and each group; a line's commission is changed by hand and the vigência published.
test('commission tables: 2tech file with Repasse mapping, view per group, edit a line, publish', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const tag = String(Date.now()).slice(-7)
  const csv = [
    'Banco;Convênio;Tabela/Nome do Produto;Código no Banco;Início;Prazo Inicial;Prazo Final;Tipo de Contrato;Taxa a.m;À Vista (Empresa);Diferido (Empresa);À Vista (Repasse 1);Plástico (Repasse 1);À Vista (Repasse 2)',
    `Banco E2E ${tag};Convênio E2E ${tag};Tabela E2E ${tag};C${tag};01/09/2026;84;84;Novo;1,66;6;12;2,5;R$ 10,00;1`,
    `Banco E2E ${tag};Convênio E2E ${tag};Tabela E2E ${tag};C${tag};01/09/2026;96;96;Novo;1,70;7;0;3;;1`,
  ].join('\n')
  await page.goto('/app/comercial/importacao-inteligente')
  await page.getByLabel('Planilha').setInputFiles({ name: `tabela-${tag}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf-8') })
  await page.getByRole('button', { name: 'Ler planilha' }).click()
  await expect(page.getByText('A planilha usa colunas Repasse. De qual grupo é cada uma?')).toBeVisible({ timeout: 30_000 })
  await page.getByLabel('Repasse 1').selectOption({ label: 'Ouro' })
  await page.getByLabel('Repasse 2').selectOption({ label: 'Não usar esta coluna' })
  // The 2tech file does not carry the base: it is chosen on screen (part C1).
  await page.getByLabel('Base de cálculo').selectOption('LÍQUIDO')
  await page.getByRole('button', { name: 'Aplicar e ver a prévia de novo' }).first().click()
  await expect(page.getByText('Grupos: Ouro')).toBeVisible({ timeout: 30_000 })
  await page.getByLabel(/Confirmo que o Diferido/).check()
  await page.getByRole('button', { name: 'Importar como rascunho' }).click()
  await expect(page.getByText(/Importação concluída/)).toBeVisible({ timeout: 30_000 })

  await page.goto(`/app/comercial/tabelas?nome=Tabela+E2E+${tag}&vigencia=todas`)
  await expect(page.getByText('1 tabela(s)', { exact: false })).toBeVisible({ timeout: 30_000 })
  await page.getByRole('link', { name: `Tabela E2E ${tag}`, exact: true }).click()
  await expect(page.getByRole('heading', { name: `Tabela E2E ${tag}` })).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText('Rascunho').first()).toBeVisible()
  const grid = page.locator('#comissao table')
  await expect(grid.getByRole('cell', { name: '6%' })).toBeVisible()
  await page.getByRole('tab', { name: 'Ouro' }).click()
  await expect(grid.getByRole('cell', { name: '2,5%' })).toBeVisible({ timeout: 30_000 })
  await expect(grid.getByRole('cell', { name: 'R$ 10,00' })).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-tabela-grupo.png`, fullPage: true })

  await grid.getByRole('link', { name: 'Alterar comissão' }).first().click()
  await page.getByLabel('À Vista — Ouro').fill('3,25')
  await page.getByRole('button', { name: 'Salvar comissão da linha' }).click()
  await expect(page.getByText('Comissão da linha salva.')).toBeVisible({ timeout: 30_000 })
  await page.getByRole('tab', { name: 'Ouro' }).click()
  await expect(page.locator('#comissao table').getByRole('cell', { name: '3,25%' })).toBeVisible({ timeout: 30_000 })
  // Start of the vigência chosen at publication (owner request 29/09/2026).
  await page.getByLabel('Início da vigência').fill('2026-01-01')
  await page.getByRole('button', { name: 'Publicar' }).click()
  await expect(page.getByText('Vigência publicada.')).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('#vigencias')).toContainText('de 01/01/2026')
  await page.getByRole('button', { name: /Nova vigência a partir da v1/ }).click()
  await expect(page.getByText(/Rascunho da nova vigência pronto/)).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('#vigencias').getByText('v2', { exact: true })).toBeVisible()
  // A start before the published v1 would overlap it: refused, the draft stays.
  await page.getByLabel('Início da vigência').fill('2025-12-01')
  await page.getByRole('button', { name: 'Publicar' }).click()
  await expect(page.getByText(/Já existe vigência publicada que começa depois/)).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('#vigencias').getByText('Rascunho')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-vigencia-data.png`, fullPage: true })
})

// Part C1 (owner decisions 26/09/2026): tax per table line, IR withheld by the bank, the contract commission with both,
// the contract search with the margin, and the table export in the import layout.
test('commission C1: line tax, bank IR, contract commission and search, table export', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const ade = `E2E-C1-${Date.now()}`
  await page.goto('/app/comercial/instituicoes')
  await page.getByLabel('IR retido de Banco Teste').fill('0,5')
  await page.getByRole('row', { name: /Banco Teste/ }).getByRole('button', { name: 'Salvar' }).first().click()
  await expect(page.getByText('IR retido do banco salvo.')).toBeVisible({ timeout: 30_000 })

  // New vigência of the test table with 6% tax on its line, published.
  await page.goto('/app/comercial/tabelas?nome=Tabela+Teste+INSS')
  await page.getByRole('link', { name: 'Tabela Teste INSS', exact: true }).click()
  await page.getByRole('button', { name: /Nova vigência a partir da v/ }).click()
  await expect(page.getByText(/Rascunho da nova vigência pronto/)).toBeVisible({ timeout: 30_000 })
  await page.locator('#comissao table').getByRole('link', { name: 'Alterar comissão' }).first().click()
  await page.getByLabel('Imposto (%)').fill('6')
  await page.getByRole('button', { name: 'Salvar comissão da linha' }).click()
  await expect(page.getByText('Comissão da linha salva.')).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('#comissao table').getByRole('cell', { name: '6%', exact: true }).first()).toBeVisible()
  await page.getByRole('button', { name: 'Publicar' }).click()
  await expect(page.getByText('Vigência publicada.')).toBeVisible({ timeout: 30_000 })
  const version = (await page.locator('#vigencias li').first().getByText(/^v\d+$/).textContent())?.trim()

  await page.goto('/app/comercial/instituicoes')
  await expect(page.getByRole('row', { name: /Banco Teste/ })).toContainText('Paga imposto')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-bancos.png`, fullPage: true })

  await page.goto('/app/propostas/nova')
  await pickClient(page)
  await page.getByLabel('Banco e tabela').selectOption({ label: `Banco Teste · Tabela Teste INSS (${version})` })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('120')
  await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
  await page.getByLabel('Já digitada no banco').check()
  await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible({ timeout: 20_000 })
  // Born calculated (ADR-0040): no click needed.
  // 600,00 received; 6% tax = 36,00; 0,5% IR = 3,00; Ouro 3% = 300,00; margin 261,00.
  const upfront = page.getByRole('row', { name: /^À vista/ })
  for (const v of ['R$ 600,00', 'R$ 36,00', 'R$ 3,00', 'R$ 300,00', 'R$ 261,00']) await expect(upfront).toContainText(v)
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-comissao-c1.png`, fullPage: true })

  await page.goto(`/app/contratos?q=${ade}`)
  const row = page.getByRole('row').filter({ hasText: ade })
  await expect(row).toContainText('Vendedor Teste')
  await expect(row).toContainText(/\d{3}\.\d{3}\.\d{3}-\d{2}/)
  // Whole contract: à vista + 120 deferred installments (2.000,00 received, 1.000,00 to the seller, margin 870,00).
  for (const v of ['R$ 2.000,00', 'R$ 1.000,00', 'R$ 870,00']) await expect(row).toContainText(v)
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contratos.png`, fullPage: true })
})

// Owner decisions 26/09/2026: "Nova pesquisa" goes back to the search with the filters marked, and the search exports
// every table it shows (one bank or all); the file imports back as new drafts on each table's own origin.
test('tables: Nova pesquisa keeps the filters; bank export imports back as drafts', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/comercial/tabelas')
  await page.locator('select[name="banco"]').selectOption({ label: 'Banco Teste' })
  await page.getByRole('button', { name: 'Pesquisar' }).click()
  await expect(page).toHaveURL(/banco=/)
  await page.getByRole('link', { name: 'Tabela Teste INSS', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Tabela Teste INSS' })).toBeVisible({ timeout: 30_000 })
  await page.getByRole('link', { name: 'Nova pesquisa' }).click()
  await expect(page).toHaveURL(/banco=/)
  await expect(page.locator('select[name="banco"] option:checked')).toHaveText('Banco Teste')

  const exportLink = page.getByRole('link', { name: /Exportar planilha/ })
  const file = await page.request.get(await exportLink.getAttribute('href') ?? '')
  expect(file.status()).toBe(200)
  const body = await file.body()
  // The export carries "Tipo de formalização" (Digital here), read back by the import.
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(body as unknown as ArrayBuffer)
  const head = (wb.getWorksheet('Tabelas')?.getRow(1).values ?? []) as unknown[]
  const formCol = head.indexOf('Tipo de formalização')
  expect(formCol).toBeGreaterThan(0)
  expect(wb.getWorksheet('Tabelas')?.getRow(2).getCell(formCol).value).toBe('Digital')

  await page.goto('/app/comercial/importacao-inteligente')
  await page.getByLabel('Planilha').setInputFiles({ name: 'tabelas-banco-teste.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: body })
  await page.getByRole('button', { name: 'Ler planilha' }).click()
  await expect(page.getByText(/A origem de cada linha vem da coluna/)).toBeVisible({ timeout: 30_000 })
  const deferred = page.getByLabel(/Confirmo que o Diferido/)
  if (await deferred.count()) await deferred.check()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-reimportar-banco.png`, fullPage: true })
  await page.getByRole('button', { name: 'Importar como rascunho' }).click()
  await expect(page.getByText(/Importação concluída: 0 tabela\(s\) nova\(s\)/)).toBeVisible({ timeout: 60_000 })

  await page.goto('/app/comercial/tabelas?nome=Tabela+Teste+INSS&vigencia=todas')
  await expect(page.getByRole('row', { name: /Tabela Teste INSS/ })).toContainText('Rascunho')
})

// Part C2 (owner decisions 26/09/2026): the owner changes the seller's payout per commission type with a reason, edits
// the contract (the commission follows), writes a note, and the Contratos screen marks and filters changed payouts.
test('contract C2: payout change, contract edit with recalculation, note and history', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const ade = `E2E-C2-${Date.now()}`
  await page.goto('/app/propostas/nova')
  await pickClient(page)
  await page.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('120')
  await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
  await page.getByLabel('Já digitada no banco').check()
  await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible({ timeout: 30_000 })
  // Born calculated (ADR-0040): no click needed.

  // 2% of the R$ 10.000,00 base instead of the rule (3% for group Ouro).
  await page.getByText('Alterar repasse do vendedor — À vista').click()
  await page.getByLabel('Repasse À vista').fill('2')
  await page.getByLabel('Motivo À vista').fill('empresa lucra mais')
  await page.getByRole('button', { name: 'Salvar repasse' }).first().click()
  await expect(page.getByText('Repasse do vendedor alterado.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByRole('row', { name: /^À vista/ })).toContainText('R$ 200,00')

  // The contract grows to R$ 12.000,00: recalculated, the change (2% of the base) follows.
  await page.getByRole('button', { name: 'Editar contrato' }).click()
  await page.getByLabel('Valor bruto (R$)').fill('12.000,00')
  await page.getByRole('button', { name: 'Salvar alterações' }).click()
  await expect(page.getByText('Contrato atualizado. A comissão foi recalculada.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByRole('row', { name: /^À vista/ })).toContainText('R$ 240,00')

  await page.getByLabel('Nova observação').fill('Cliente pediu retorno amanhã.')
  await page.getByRole('button', { name: 'Registrar observação' }).click()
  await expect(page.getByText('Observação registrada.')).toBeVisible({ timeout: 30_000 })
  const history = page.locator('#historico')
  await expect(history).toContainText('Valor bruto: R$ 10.000,00 → R$ 12.000,00')
  await expect(history).toContainText('Repasse do vendedor (à vista)')
  await expect(history).toContainText('Cliente pediu retorno amanhã.')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contrato-c2.png`, fullPage: true })

  await page.goto(`/app/contratos?alterado=1&q=${ade}`)
  const row = page.getByRole('row').filter({ hasText: ade })
  await expect(row).toContainText('Alterado')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contratos-alterados.png`, fullPage: true })
})

// Part C3 (owner decisions 26/09/2026): the seller's commission is released only when the contract is paid to the client
// (physical: once the company received the file) and the bank's commission was received and reconciled; a payment made
// outside Corban is registered even before the bank pays and locks the contract; Contratos filters by payout status.
test('seller credit C3: paid date, bank reconciliation, physical milestones, outside payment', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const today = new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 10)
  const create = async (ade: string) => {
    await page.goto('/app/propostas/nova')
    await pickClient(page)
    await page.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
    await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
    await page.getByLabel('Prazo (meses)').fill('120')
    await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
    await page.getByLabel('Já digitada no banco').check()
    await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
    await page.getByRole('button', { name: 'Registrar proposta' }).click()
    await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible({ timeout: 30_000 })
  }
  const pay = async () => {
    await page.getByLabel('Mover para').selectOption('paid')
    await page.getByLabel('Observação', { exact: true }).fill('Pago ao cliente')
    await page.getByLabel('Pago ao cliente em').fill(today)
    await page.getByRole('button', { name: 'Salvar etapa' }).click()
    await expect(page.getByText('Etapa atualizada.')).toBeVisible({ timeout: 30_000 })
  }
  // The bank's à vista report with this contract (exact 600,00), confirmed by finance.
  const receive = async (ade: string) => {
    const back = page.url().split('?')[0]
    const csv = `Contrato;Valor comissão;Pago em
${ade};600,00;10/09/2026
`
    await page.goto('/app/financeiro/importar')
    await page.getByLabel('Fonte pagadora').selectOption({ label: 'Banco Teste · banco' })
    await page.getByLabel('Tipo do relatório').selectOption('upfront')
    await page.getByLabel(/Arquivo/).setInputFiles({ name: `avista-${ade}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf-8') })
    await page.getByRole('button', { name: 'Ler colunas do arquivo' }).click()
    await page.getByLabel(/Contrato \(ADE/).selectOption('Contrato')
    await page.getByLabel(/Valor da comissão/).selectOption('Valor comissão')
    await page.getByLabel(/Data do pagamento/).selectOption('Pago em')
    await page.getByRole('button', { name: 'Importar para conferência' }).click()
    await expect(page.getByText('Relatório importado.')).toBeVisible({ timeout: 20_000 })
    await page.getByRole('button', { name: 'Confirmar e lançar recebimentos' }).click()
    await expect(page.getByText('Relatório confirmado.')).toBeVisible({ timeout: 20_000 })
    await page.goto(back)
  }

  // Digital, paid to the client, the bank has not paid: the owner registers a payment already made outside Corban.
  const ade1 = `E2E-C3-${Date.now()}`
  await create(ade1)
  await expect(page.locator('#comissao')).toContainText('Aguardando pagamento ao cliente')
  await pay()
  await expect(page.locator('#comissao')).toContainText('Aguardando comissão do banco')
  await page.getByText('Registrar pagamento feito fora do Corban').click()
  await page.getByLabel('Pago em').fill(today)
  await page.getByLabel('Comprovante / referência').fill('PIX E2E C3')
  await page.getByRole('button', { name: 'Registrar pagamento' }).click()
  await expect(page.getByText(/Pagamento feito fora do Corban registrado/)).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('#comissao')).toContainText('Pago ao vendedor em')
  await expect(page.locator('#contrato')).toContainText('Vendedor já recebeu')

  // Physical: the table says physical; the credit waits for the file received by the company.
  await page.goto('/app/comercial/tabelas?nome=Tabela+Teste+INSS')
  await page.getByRole('link', { name: 'Tabela Teste INSS', exact: true }).click()
  await page.getByLabel('Formalização dos contratos').selectOption('physical')
  await page.getByRole('button', { name: 'Salvar formalização' }).click()
  await expect(page.getByText('Formalização da tabela salva.')).toBeVisible({ timeout: 30_000 })
  const ade2 = `E2E-C3F-${Date.now()}`
  await create(ade2)
  await pay()
  await expect(page.locator('#comissao')).toContainText('Aguardando o físico')
  await page.locator('#fisico').getByRole('button', { name: 'Registrar' }).click()
  await expect(page.getByText('Físico registrado.')).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('#comissao')).toContainText('Aguardando comissão do banco')
  await receive(ade2)
  await expect(page.locator('#comissao')).toContainText('Liberado R$ 300,00')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contrato-c3.png`, fullPage: true })

  await page.goto(`/app/contratos?repasse=pago&q=${ade1}`)
  await expect(page.getByRole('row').filter({ hasText: ade1 })).toContainText('pago em')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-contratos-repasse.png`, fullPage: true })

  // Back to digital, so the other tests keep their table as they expect it.
  await page.goto('/app/comercial/tabelas?nome=Tabela+Teste+INSS')
  await page.getByRole('link', { name: 'Tabela Teste INSS', exact: true }).click()
  await page.getByLabel('Formalização dos contratos').selectOption('digital')
  await page.getByRole('button', { name: 'Salvar formalização' }).click()
  await expect(page.getByText('Formalização da tabela salva.')).toBeVisible({ timeout: 30_000 })
})

// F5.5 (map 16a): the legacy base comes in by file with a preview, never enters the pipeline and shows on the client file.
test('legacy base: cutoff, file preview with refused lines, import, client file, undo', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  // A valid CPF that no other run has used.
  const digits = String(Date.now()).slice(-9).split('').map(Number)
  const dv = (d: number[]) => { const s = d.reduce((a, n, i) => a + n * (d.length + 1 - i), 0) % 11; return s < 2 ? 0 : 11 - s }
  const cpf = [...digits, dv(digits), dv([...digits, dv(digits)])].join('')
  const name = `Cliente Antigo E2E ${Date.now()}`
  const ade = `LEG-${Date.now()}`

  await page.goto('/app/configuracao/base-antiga')
  await page.getByLabel('Início do uso do Corban').fill('2026-09-01')
  await page.getByRole('button', { name: 'Salvar data de corte' }).click()
  await expect(page.getByText('Data de corte salva.')).toBeVisible({ timeout: 30_000 })

  const csv = `CPF;Nome do Cliente;Banco;Contrato;Data Contrato;Valor Bruto;Parcela;Prazo;Corretor;Situação\n`
    + `${cpf};${name};Banco Antigo;${ade};10/05/2025;10.000,00;250,00;96;Vendedor Teste;PAGO\n`
    + `11111111111;CPF Errado;Banco Antigo;${ade}-X;10/05/2025;1.000,00;;;;\n`
    + `${cpf};${name};Banco Antigo;${ade}-NOVO;10/09/2026;2.000,00;;;;\n`
  await page.getByLabel(/Arquivo exportado/).setInputFiles({ name: `base-${Date.now()}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf-8') })
  await page.getByRole('button', { name: 'Ler colunas do arquivo' }).click()
  await expect(page.getByLabel(/CPF do cliente/)).toHaveValue('CPF', { timeout: 30_000 })
  await page.getByRole('button', { name: 'Enviar para conferência' }).click()
  await expect(page.getByText('Arquivo lido. Confira as linhas antes de confirmar: nada foi gravado ainda.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText('CPF inválido', { exact: true })).toBeVisible()
  await expect(page.getByText('Contrato depois da data de corte (entra pela esteira)', { exact: true })).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-base-antiga-conferencia.png`, fullPage: true })
  await page.getByRole('button', { name: 'Confirmar importação' }).click()
  await expect(page.getByText('Base antiga importada.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText(/1 cliente\(s\) novo\(s\), 0 já existente\(s\), 1 contrato\(s\)/)).toBeVisible()
  const batchUrl = page.url().split('?')[0]

  await page.goto(`/app/clientes?q=${encodeURIComponent(name)}`)
  await page.getByRole('link', { name }).first().click()
  await expect(page.getByText('Contratos antigos')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText(ade, { exact: true })).toBeVisible()
  await expect(page.getByText('Origem: base antiga (2tech)')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-base-antiga-ficha.png`, fullPage: true })

  await page.goto(batchUrl)
  await page.getByText('Desfazer esta importação').click()
  await page.getByLabel('Motivo').fill('teste e2e')
  await page.getByRole('button', { name: 'Desfazer', exact: true }).click()
  await expect(page.getByText('Importação desfeita.')).toBeVisible({ timeout: 30_000 })
})

// The 2tech export has 6 MB: the file is read in the browser and sent in blocks, so a file bigger than the server's
// request limit (4.5 MB on Vercel) still comes in.
test('legacy base: a file bigger than the request limit is read in the browser and sent in blocks', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const pad = 'x'.repeat(3000)
  const lines = ['CPF;Nome do Cliente;Contrato;Data Contrato;Observacao']
  for (let i = 1; i <= 2600; i++) lines.push(`000.000.000-00;Linha ${i};BIG-${Date.now()}-${i};10/05/2025;${pad}`)
  const buffer = Buffer.from(lines.join(String.fromCharCode(10)), 'utf-8')
  expect(buffer.length).toBeGreaterThan(7_000_000)
  await page.goto('/app/configuracao/base-antiga')
  await page.getByLabel(/Arquivo exportado/).setInputFiles({ name: `grande-${Date.now()}.csv`, mimeType: 'text/csv', buffer })
  await page.getByRole('button', { name: 'Ler colunas do arquivo' }).click()
  await expect(page.getByText('2600 linha(s) após os títulos.', { exact: false })).toBeVisible({ timeout: 60_000 })
  await page.getByRole('button', { name: 'Enviar para conferência' }).click()
  await expect(page.getByText('Arquivo lido. Confira as linhas antes de confirmar: nada foi gravado ainda.')).toBeVisible({ timeout: 180_000 })
  await expect(page.getByText(/2600 linha\(s\)/)).toBeVisible()
  await expect(page.getByText(/CPF inválido: 2600/)).toBeVisible()
  await page.getByRole('button', { name: 'Descartar' }).click()
  await expect(page.getByText('Importação descartada.')).toBeVisible({ timeout: 30_000 })
})

// F6.5: company finance — bank account, a payable, the OFX statement reconciled (a match and a bank fee), reports.
test('company finance: bank account, payable, OFX reconciliation, cash flow and DRE', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const ts = Date.now()
  const cents = String(ts % 100).padStart(2, '0')
  const value = `2${String(ts % 97).padStart(2, '0')},${cents}`
  const ofxValue = `-2${String(ts % 97).padStart(2, '0')}.${cents}`
  const bill = `Energia E2E ${ts}`
  const bank = `C6 E2E ${ts}`

  await page.goto('/app/financeiro/empresa/contas')
  const newAccount = page.locator('section').filter({ has: page.getByText('Nova conta', { exact: true }) }).last()
  await newAccount.getByLabel('Nome da conta').fill(bank)
  await newAccount.getByLabel('Saldo inicial (R$)').fill('1.000,00')
  await newAccount.getByRole('button', { name: 'Cadastrar conta' }).click()
  await expect(page.getByText('Conta bancária salva.')).toBeVisible({ timeout: 30_000 })

  await page.goto('/app/financeiro/empresa')
  await page.getByText('+ Novo lançamento').click()
  await page.getByLabel('Descrição').fill(bill)
  await page.getByLabel('Conta do plano').selectOption({ label: '4.4 Energia, água e internet' })
  await page.getByLabel('Valor total (R$)').fill(value)
  await page.getByRole('button', { name: 'Registrar' }).click()
  await expect(page.getByText('Lançamento registrado.')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByRole('row').filter({ hasText: bill })).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-financeiro-empresa.png`, fullPage: true })

  const day = new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 10).replace(/-/g, '')
  const ofx = `OFXHEADER:100\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>\n`
    + `<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>${day}<TRNAMT>${ofxValue}<FITID>E2E-${ts}-1<MEMO>ENERGIA ${ts}\n`
    + `<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>${day}<TRNAMT>-3.21<FITID>E2E-${ts}-2<MEMO>TARIFA E2E ${ts}\n`
    + `</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`
  await page.goto('/app/financeiro/empresa/extrato')
  await page.getByLabel('Conta bancária do extrato').selectOption({ label: bank })
  await page.getByLabel('Extrato (arquivo OFX)').setInputFiles({ name: `extrato-${ts}.ofx`, mimeType: 'application/x-ofx', buffer: Buffer.from(ofx, 'utf-8') })
  await page.getByRole('button', { name: 'Importar extrato' }).click()
  await expect(page.getByText('2 lançamento(s) lidos do extrato.')).toBeVisible({ timeout: 30_000 })
  const energyLine = page.locator('li').filter({ hasText: `ENERGIA ${ts}` })
  await expect(energyLine.getByText(bill)).toBeVisible({ timeout: 30_000 })
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-financeiro-extrato.png`, fullPage: true })
  await energyLine.getByRole('button', { name: 'Conciliar' }).click()
  await expect(page.getByText('Linha do extrato conciliada.')).toBeVisible({ timeout: 30_000 })
  const feeLine = page.locator('li').filter({ hasText: `TARIFA E2E ${ts}` })
  await feeLine.getByText(/Criar lançamento/).click()
  await feeLine.getByLabel('Conta do plano').selectOption({ label: '5.2 Tarifas bancárias e juros' })
  await feeLine.getByRole('button', { name: 'Criar' }).click()
  await expect(page.getByText('Linha do extrato conciliada.')).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('li').filter({ hasText: `TARIFA E2E ${ts}` })).toHaveCount(0)

  await page.goto('/app/financeiro/empresa?ver=baixados')
  await expect(page.getByRole('row').filter({ hasText: bill })).toContainText(bank)
  await page.goto('/app/financeiro/empresa/relatorios')
  await expect(page.getByText('4.4 Energia, água e internet')).toBeVisible({ timeout: 30_000 })
  await expect(page.getByText('5.2 Tarifas bancárias e juros')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-financeiro-dre.png`, fullPage: true })
  await page.goto('/app/financeiro/empresa/a-lancar')
  await expect(page.getByText(/Automático:|Manual:/)).toBeVisible({ timeout: 30_000 })
})

// Validation (27/09/2026): simulation in the new look, client picked by search (works past 300 clients), amount typed
// as "10.000,00" (exact decimal, no float), and the simulation becomes a proposal.
test('simulation: pick the client by search, simulate, turn into a proposal', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/propostas')
  await page.getByRole('link', { name: 'Simular' }).click()
  await expect(page.getByRole('heading', { name: 'Simulações', exact: true })).toBeVisible()
  await pickClient(page)
  // Only tables in force, each paired with the contract types of its conditions.
  await expect(page.locator('select[name="table_choice"] option', { hasText: 'Tabela Teste INSS · v1' })).toHaveCount(0)
  await page.locator('select[name="table_choice"]').selectOption({ label: 'Tabela Teste INSS · v3 · Novo (teste) · 12–120 meses' })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('84')
  await page.getByRole('button', { name: 'Simular' }).click()
  await expect(page.getByText('Simulação registrada')).toBeVisible()
  const row = page.getByRole('row').filter({ hasText: 'Ana Teste Lopes' }).first()
  await expect(row).toContainText('R$ 10.000,00')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-simulacoes.png`, fullPage: true })
  await row.getByRole('button', { name: 'Criar proposta' }).click()
  await expect(page).toHaveURL(/\/app\/propostas/)
})

test('sales CRM: campaign, spreadsheet, take the next lead, return, simulate, board', async ({ page, browser }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const stamp = Date.now().toString().slice(-7)
  const name = `Campanha E2E ${stamp}`
  await page.goto('/app/crm/campanhas')
  await page.getByLabel('Nome da campanha').fill(name)
  await page.getByRole('button', { name: 'Criar campanha' }).click()
  await expect(page.getByText('Campanha criada. Agora suba a planilha.')).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole('heading', { name })).toBeVisible()
  const campaignId = page.url().match(/campanhas\/([0-9a-f-]{36})/)![1]
  // The upload button and the Excel template are in plain sight.
  await expect(page.getByRole('link', { name: 'Subir planilha' })).toBeVisible()
  const [download] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Baixar modelo em Excel' }).first().click()])
  expect(download.suggestedFilename()).toBe('modelo-campanha-corban.xlsx')
  const template = new ExcelJS.Workbook()
  await template.xlsx.readFile(await download.path())
  expect((template.getWorksheet('Leads')!.getRow(1).values as unknown[]).slice(1, 4)).toEqual(['Nome', 'CPF', 'Telefone'])

  // Spreadsheet: name, CPF, phone and a margin column; the header names are recognized.
  const csv = ['Nome;CPF;Telefone;Margem', `Lead E2E Um;314.159.265-90;(68) 9${stamp.slice(0, 4)}-${stamp.slice(3)};350,20`, `Lead E2E Dois;;(68) 8${stamp.slice(0, 4)}-${stamp.slice(3)};120,00`, ';;;'].join('\n')
  await page.getByLabel('Planilha da campanha').setInputFiles({ name: 'campanha.csv', mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf-8') })
  await expect(page.getByLabel('Coluna Nome')).toHaveValue('0')
  await expect(page.getByLabel('Coluna CPF')).toHaveValue('1')
  await expect(page.getByLabel('Coluna Telefone', { exact: true })).toHaveValue('2')
  await expect(page.getByRole('checkbox', { name: 'Margem' })).toBeChecked()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-crm-importar.png`, fullPage: true })
  await page.getByRole('button', { name: 'Importar 2 lead(s)' }).click()
  await expect(page.getByText(/Importação concluída: 2 lead\(s\) novo\(s\)/)).toBeVisible({ timeout: 20_000 })

  // The queue gives the first line of the file; the lead file shows the spreadsheet columns.
  await page.goto(`/app/crm?campanha=${campaignId}`)
  await page.getByRole('button', { name: /Pegar próximo lead/ }).click()
  await expect(page.getByRole('heading', { name: /Lead E2E Um/ })).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText('350,20')).toBeVisible()
  await expect(page.getByText('314.159.265-90')).toBeVisible()
  await page.getByLabel('Quando retornar').fill('2030-01-15T10:30')
  await page.getByLabel('Anotação (opcional)').fill('Cliente pediu retorno de manhã')
  await page.getByRole('button', { name: 'Marcar retorno' }).click()
  await expect(page.getByText('Retorno marcado.')).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText('Em contato', { exact: true }).first()).toBeVisible()
  await expect(page.getByText('Cliente pediu retorno de manhã')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-crm-lead.png`, fullPage: true })

  // Simular: the lead's CPF makes the client and the simulation opens with it chosen.
  await page.getByRole('button', { name: 'Simular' }).click()
  await expect(page).toHaveURL(/\/app\/simulacoes\?cliente=[0-9a-f-]{36}$/, { timeout: 20_000 })
  await expect(page.getByText('Lead E2E Um')).toBeVisible()

  // Board: the lead is negotiating; the second one is dragged from Novo to Em contato.
  await page.goto(`/app/crm?campanha=${campaignId}`)
  await expect(page.getByRole('region', { name: /^Negociando: 1$/ })).toContainText('Lead E2E Um')
  const second = page.getByRole('region', { name: /^Novo: 1$/ }).getByRole('link', { name: /Lead E2E Dois/ })
  await second.dragTo(page.getByRole('region', { name: /^Em contato/ }))
  await expect(page.getByRole('region', { name: /^Em contato: 1$/ })).toContainText('Lead E2E Dois', { timeout: 20_000 })
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-crm-quadro.png`, fullPage: true })

  // Campaign numbers.
  await page.goto(`/app/crm/campanhas/${campaignId}`)
  await expect(page.getByText('campanha.csv')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-crm-campanha.png`, fullPage: true })

  // A seller works the board but does not manage campaigns, and never sees the leads of the queue.
  const sellerEmail = process.env.E2E_SELLER_EMAIL
  if (!sellerEmail) return
  const seller = await (await browser.newContext({ storageState: { cookies: [], origins: [] } })).newPage()
  await seller.goto('/login')
  await seller.locator('input[type="email"]').fill(sellerEmail)
  await seller.locator('input[type="password"]').fill(password!)
  await seller.locator('button[type="submit"]').click()
  await seller.waitForURL(/\/app(\/|$)/)
  await seller.goto(`/app/crm?campanha=${campaignId}`)
  await expect(seller.getByRole('heading', { name: 'Vendas' })).toBeVisible()
  await expect(seller.getByRole('link', { name: 'Campanhas' })).toHaveCount(0)
  await expect(seller.getByText('Lead E2E Dois')).toHaveCount(0)
  await seller.goto('/app/crm/campanhas')
  await expect(seller).toHaveURL(/\/app\/crm$/)
})

test('documents: pick the client by search, a standard type, send a file', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/documentos')
  await pickClient(page)
  await page.locator('select[name="document_type_id"]').selectOption({ label: 'RG (documento de identidade)' })
  // A tiny valid PNG, different on every run (the vault refuses the same file twice).
  const png = Buffer.concat([Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000' + '1f15c489', 'hex'), Buffer.from(`run-${Date.now()}`)])
  await page.locator('input[name="file"]').setInputFiles({ name: 'rg.png', mimeType: 'image/png', buffer: png })
  await page.getByRole('button', { name: /Enviar/ }).click()
  await expect(page.getByText('Documento enviado.')).toBeVisible({ timeout: 20_000 })
  await expect(page.locator('main')).toContainText('Ana Teste Lopes')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-documentos.png`, fullPage: true })
})

test('documents per bank: the list of Banco Teste becomes the checklist of a new proposal', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/cadastros')
  await page.locator('main').getByRole('link', { name: /Documentos por banco/ }).click()
  await page.getByRole('link', { name: /^Banco Teste/ }).first().click()
  await expect(page.getByRole('heading', { name: 'Definir a lista de Banco Teste' })).toBeVisible()
  await page.getByRole('checkbox', { name: 'Pede RG (documento de identidade)' }).check()
  await page.getByRole('checkbox', { name: 'Pede Comprovante de residência' }).check()
  await page.getByLabel('Obrigatório Comprovante de residência').selectOption('optional')
  await page.getByRole('button', { name: 'Salvar lista' }).click()
  await expect(page.getByText('Lista de documentos salva.')).toBeVisible({ timeout: 20_000 })
  await expect(page.getByText('Comprovante de residência (opcional) · RG (documento de identidade)').first()).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-documentos-banco.png`, fullPage: true })

  // A proposal of that bank prepares its checklist from the list.
  await page.goto('/app/simulacoes')
  await pickClient(page)
  await page.locator('select[name="table_choice"]').selectOption({ label: 'Tabela Teste INSS · v3 · Novo (teste) · 12–120 meses' })
  await page.getByLabel('Valor solicitado (R$)').fill('5.000,00')
  await page.getByLabel('Prazo (meses)').fill('84')
  await page.getByRole('button', { name: 'Simular' }).click()
  await expect(page.getByText('Simulação registrada')).toBeVisible()
  const row = page.getByRole('row').filter({ hasText: 'Ana Teste Lopes' }).filter({ hasText: 'R$ 5.000,00' }).first()
  await row.getByRole('button', { name: 'Criar proposta' }).click()
  await expect(page).toHaveURL(/\/app\/propostas/)
  await page.goto('/app/simulacoes')
  await page.getByRole('row').filter({ hasText: 'R$ 5.000,00' }).first().getByRole('link', { name: 'Abrir proposta' }).click()
  await page.getByRole('button', { name: 'Preparar checklist' }).click()
  await expect(page.getByText('Checklist de documentos preparado.')).toBeVisible({ timeout: 20_000 })
  await expect(page.locator('main')).toContainText('RG (documento de identidade)')
  await expect(page.locator('main')).toContainText('Comprovante de residência')
  // The file is sent right on the checklist item and linked to it.
  const png = Buffer.concat([Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000' + '1f15c489', 'hex'), Buffer.from(`rg-${Date.now()}`)])
  await page.getByLabel('Arquivo RG (documento de identidade)').setInputFiles({ name: 'rg.png', mimeType: 'image/png', buffer: png })
  await page.getByRole('button', { name: 'Enviar arquivo' }).first().click()
  await expect(page.getByText('Anexado, falta validar').first()).toBeVisible({ timeout: 20_000 })
})

test('client file: send a document right on the client page', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/clientes')
  await page.getByRole('link', { name: 'Ana Teste Lopes' }).first().click()
  await page.getByLabel('Tipo de documento').selectOption({ label: 'Comprovante de residência' })
  const png = Buffer.concat([Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000' + '1f15c489', 'hex'), Buffer.from(`res-${Date.now()}`)])
  await page.getByLabel('Arquivo do documento').setInputFiles({ name: 'conta-luz.png', mimeType: 'image/png', buffer: png })
  await page.getByRole('button', { name: 'Enviar documento' }).click()
  await expect(page.getByText('Documento enviado.')).toBeVisible({ timeout: 20_000 })
  await expect(page).toHaveURL(/\/app\/clientes\/[0-9a-f-]{36}/)
  await expect(page.locator('#documentos')).toContainText('conta-luz.png')
})

test('phone: the bottom bar has Vendas and "Mais" opens the whole menu with Sair', async ({ page }, info) => {
  test.skip(info.project.name !== 'mobile', 'phone only')
  await page.goto('/app/hoje')
  const bar = page.getByRole('navigation', { name: 'Navegação inferior' })
  await expect(bar.getByRole('link', { name: 'Vendas' })).toBeVisible()
  await bar.getByRole('button', { name: 'Mais' }).click()
  const menu = page.getByRole('dialog', { name: 'Menu' })
  await expect(menu.getByRole('link', { name: 'Contratos' })).toBeVisible()
  await expect(menu.getByRole('button', { name: 'Sair' })).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-menu.png` })
  await menu.getByRole('link', { name: 'Contratos' }).click()
  await expect(page).toHaveURL(/\/app\/contratos/, { timeout: 30_000 })
  await expect(page.getByRole('dialog', { name: 'Menu' })).toHaveCount(0)
})

test('phone: Esteira shows one card per proposal, without the wide table', async ({ page }, info) => {
  test.skip(info.project.name !== 'mobile', 'phone only')
  await page.goto('/app/propostas')
  const list = page.getByRole('list', { name: 'Propostas' })
  await expect(list).toBeVisible()
  await expect(page.locator('table')).toBeHidden()
  await expect(list.getByRole('link').first()).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-esteira-lista.png` })
  const width = await page.evaluate(() => document.documentElement.scrollWidth)
  expect(width).toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth))
})
