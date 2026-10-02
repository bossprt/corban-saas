import { expect, test, type Page } from '@playwright/test'
import ExcelJS from 'exceljs'

// Contract import with the NASP layout. Needs a local or test database with the bank NASP and its tables
// (supabase/migrations/20261002052952_nasp_acre_tables_v1.sql run on a company with NASP + Governo do Acre);
// without them the test is skipped. All people and numbers here are made up.
const email = process.env.E2E_EMAIL
const password = process.env.E2E_PASSWORD
const shots = process.env.E2E_SCREENSHOTS

test.skip(!email || !password, 'E2E_EMAIL and E2E_PASSWORD are not set')
test.setTimeout(180_000)

// A valid CPF from 9 random digits (check digits computed), so every run uses new clients.
const fakeCpf = () => {
  const d = Array.from({ length: 9 }, (_, i) => (i === 0 ? 9 : Math.floor(Math.random() * 10)))
  for (const n of [10, 11]) { const s = d.reduce((a, v, i) => a + v * (n - i), 0); const r = (s * 10) % 11; d.push(r === 10 ? 0 : r) }
  return d.join('')
}
const HEAD = ['CPF *', 'Nome', 'Tabela *', 'Prazo (meses) *', 'Valor liberado', 'Valor da parcela', 'Nº contrato/ADE', 'Tipo', 'Etapa',
  'Pago ao cliente em', 'Vendedor', 'Banco de origem', 'Contrato de origem', 'Saldo devedor', 'Observação', 'Matrícula']
const xlsx = async (rows: (string | number)[][]) => {
  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet('Contratos')
  ws.addRow(HEAD)
  for (const r of rows) ws.addRow(r)
  return Buffer.from(await wb.xlsx.writeBuffer())
}

const login = async (page: Page) => {
  await page.goto('/login')
  await page.locator('input[type="email"]').fill(email!)
  await page.locator('input[type="password"]').fill(password!)
  await page.locator('button[type="submit"]').click()
  await page.waitForURL(/\/app(\/|$)/)
}

test('NASP layout: template, check, refuse errors, import, no duplicates', async ({ page }, info) => {
  await login(page)
  const template = await page.request.get('/api/propostas/importar/modelo?layout=nasp')
  expect(template.ok()).toBeTruthy()
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load((await template.body()) as unknown as ExcelJS.Buffer)
  const tables = (wb.getWorksheet('Tabelas')?.getSheetValues() ?? []).slice(2).map(r => String((r as ExcelJS.CellValue[])?.[1] ?? ''))
  test.skip(!tables.some(t => t.includes('Temporário (8 a 18 meses)')), 'no NASP tables in this database')
  expect((wb.worksheets[0].getRow(1).values as ExcelJS.CellValue[]).slice(1, 4)).toEqual(['CPF *', 'Nome', 'Tabela *'])

  await page.goto('/app/propostas')
  await page.getByRole('link', { name: 'Importar planilha' }).click()
  await expect(page.getByRole('heading', { name: 'Importar contratos' })).toBeVisible()

  const tag = String(Date.now()).slice(-7)
  const [a, b, c] = [fakeCpf(), fakeCpf(), fakeCpf()]
  const good: (string | number)[][] = [
    [a, 'CLIENTE FICTICIO UM', 'Temporário (8 a 18 meses)', 12, '1.500,00', '150,00', `NT${tag}1`, '', '', '', 'Vendedor Teste', '', '', '', '', '777'],
    [b, 'CLIENTE FICTICIO DOIS', 'Normal - Efetivo / Pensionista', 48, 5000, '', `NT${tag}2`, '', 'paga', '01/10/2026', '', '', '', '', 'Pago pela planilha', ''],
    [c, 'CLIENTE FICTICIO TRES', 'COMPRA NORMAL', 60, '8.000,00', '', '', 'compra', 'fila', '', '', 'Banco X', '998877', '3.000,00', '', ''],
  ]

  // Errors: term outside the table and an unknown seller. Nothing can be imported.
  const bad = [[...good[0]], [...good[1]]]
  bad[0][3] = 30
  bad[1][10] = 'Fulano Inexistente'
  await page.getByLabel('Planilha (.xlsx)').setInputFiles({ name: 'nasp-erro.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: await xlsx(bad) })
  await page.getByRole('button', { name: 'Conferir' }).click()
  await expect(page.getByText('Prazo 30 fora da tabela (8 a 18)')).toBeVisible()
  await expect(page.getByText('Vendedor "Fulano Inexistente" não encontrado')).toBeVisible()
  await expect(page.getByText('Colunas ignoradas (não são campos do Corban): Matrícula')).toBeVisible()
  await expect(page.getByRole('button', { name: /Importar 0 contrato/ })).toBeDisabled()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-importar-erros.png`, fullPage: true })

  // Good file: three lines checked, then imported.
  await page.getByLabel('Planilha (.xlsx)').setInputFiles({ name: 'nasp.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: await xlsx(good) })
  await page.getByRole('button', { name: 'Conferir' }).click()
  await expect(page.getByText('3 linha(s): 3 para cadastrar, 0 já no Corban, 0 com erro.')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-importar-conferencia.png`, fullPage: true })
  await page.getByRole('button', { name: 'Importar 3 contrato(s)' }).click()
  await expect(page.getByText('Importação concluída: 3 cadastrado(s), 0 já existia(m), 0 com erro.')).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-importar-concluido.png`, fullPage: true })

  // The same file again: everything is already in Corban.
  await page.getByLabel('Planilha (.xlsx)').setInputFiles({ name: 'nasp.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: await xlsx(good) })
  await page.getByRole('button', { name: 'Conferir' }).click()
  await expect(page.getByText('3 linha(s): 0 para cadastrar, 3 já no Corban, 0 com erro.')).toBeVisible()

  // The paid one is in the pipeline as Paga.
  await page.goto('/app/propostas?etapa=paga')
  await expect(page.getByText(`NT${tag}2`).filter({ visible: true }).first()).toBeVisible()
  // The one without ADE waits in the queue.
  await page.goto('/app/propostas?etapa=fila_digitacao')
  await expect(page.getByText('CLIENTE FICTICIO TRES').filter({ visible: true }).first()).toBeVisible()
  if (shots) await page.screenshot({ path: `${shots}/${info.project.name}-importar-contrato-pago.png`, fullPage: true })
})
