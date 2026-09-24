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
  await page.getByLabel('Cliente').selectOption({ index: 1 })
  await page.getByLabel('Banco e tabela').selectOption({ index: 1 })
  await page.getByLabel('Valor liberado (R$)').fill('9.500,00')
  await page.getByLabel('Prazo (meses)').fill('84')
  await page.getByLabel('Já digitada no banco').check()
  await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible()

  const due = new Date(Date.now() + 3 * 86_400_000).toISOString().slice(0, 10)
  await page.getByLabel('Mover para').selectOption('pending_external')
  await page.getByLabel('Observação').fill('Falta comprovante de residência')
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
  await page.getByLabel('Observação').fill('Pago no portal do Banco Teste')
  await page.getByRole('button', { name: 'Salvar etapa' }).click()
  await expect(page.getByText('Etapa atualizada.')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-proposta-paga.png`, fullPage: true })

  await page.goto('/app/propostas?etapa=paga')
  await expect(page.getByText(ade)).toBeVisible()
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

test('owner configures the commission and the proposal shows the approved example', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  await page.goto('/app/configuracao/comissao')
  await page.getByLabel('Cascata: imposto').check()
  await page.getByLabel('Imposto do regime (%)').fill('6')
  await page.getByLabel(/Lucro da empresa/).fill('40')
  await page.getByLabel('Gerente (%)').first().fill('10')
  await page.getByLabel('Supervisor (%)').first().fill('15')
  await page.getByLabel(/Vendedor \(%\)/).first().fill('75')
  await page.getByRole('button', { name: 'Salvar nova versão' }).click()
  await expect(page.getByText('Regra de comissão salva')).toBeVisible()

  await page.goto('/app/propostas/nova')
  await page.getByLabel('Cliente').selectOption({ index: 1 })
  await page.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('120')
  await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible()

  await page.getByRole('button', { name: 'Calcular comissão' }).click()
  await expect(page.getByText('Comissão calculada e congelada nesta proposta.')).toBeVisible()
  const upfront = page.getByRole('row', { name: /^À vista/ })
  await expect(upfront).toContainText('R$ 600,00')
  await expect(upfront).toContainText('R$ 36,00')
  await expect(upfront).toContainText('R$ 253,80')
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-comissao.png`, fullPage: true })
})

test('finance imports a bank report, resolves the lines and confirms the receipt', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'one run is enough')
  const ade = `E2E-REC-${Date.now()}`
  await page.goto('/app/configuracao/comissao')
  await page.getByLabel('Cascata: imposto').check()
  await page.getByLabel('Imposto do regime (%)').fill('6')
  await page.getByLabel(/Lucro da empresa/).fill('40')
  await page.getByLabel('Gerente (%)').first().fill('10')
  await page.getByLabel('Supervisor (%)').first().fill('15')
  await page.getByLabel(/Vendedor \(%\)/).first().fill('75')
  await page.getByRole('button', { name: 'Salvar nova versão' }).click()
  await expect(page.getByText('Regra de comissão salva')).toBeVisible()

  await page.goto('/app/propostas/nova')
  await page.getByLabel('Cliente').selectOption({ index: 1 })
  await page.getByLabel('Banco e tabela').selectOption({ label: 'Banco Teste · Tabela Teste INSS (v2)' })
  await page.getByLabel('Valor solicitado (R$)').fill('10.000,00')
  await page.getByLabel('Prazo (meses)').fill('120')
  await page.getByLabel('Vendedor').selectOption({ label: 'Vendedor Teste' })
  await page.getByLabel('Já digitada no banco').check()
  await page.getByLabel('Número da proposta no banco (ADE)').fill(ade)
  await page.getByRole('button', { name: 'Registrar proposta' }).click()
  await expect(page.getByText('Proposta registrada na esteira.')).toBeVisible()
  await page.getByRole('button', { name: 'Calcular comissão' }).click()
  await expect(page.getByText('Comissão calculada e congelada nesta proposta.')).toBeVisible()
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
    await expect(page.getByText('Conta aberta.')).toBeVisible()
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
