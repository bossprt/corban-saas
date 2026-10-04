import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { CONTRACT_LAYOUTS } from '@/lib/imports/contract-layout'

export const dynamic = 'force-dynamic'

// The contract import template of a layout: the columns the import reads (required ones marked with *), choice lists
// for Tipo, Etapa and Tabela, and a second sheet with the bank's tables in force, so the names match exactly.
const COLUMNS: [string, string][] = [
  ['CPF *', 'CPF do cliente. Acha o cliente ou cria um novo, sem duplicar.'],
  ['Nome', 'Obrigatório só quando o cliente ainda não existe no Corban.'],
  ['Tabela *', 'Nome da tabela, como na aba Tabelas.'],
  ['Prazo (meses) *', 'Conferido contra a faixa de prazo da tabela.'],
  ['Valor liberado', 'Preencha o valor liberado ou o solicitado (pelo menos um).'],
  ['Valor solicitado', ''],
  ['Valor da parcela', ''],
  ['Nº contrato/ADE', 'O mesmo número de novo não duplica o contrato.'],
  ['Tipo', 'Vazio: o tipo da tabela, quando ela tem um só.'],
  ['Etapa', 'Vazio: Em análise no banco com ADE, Aguardando digitação sem ADE.'],
  ['Pago ao cliente em', 'Obrigatório quando a Etapa é paga.'],
  ['Vendedor', 'Nome de alguém da equipe, como está no Corban.'],
  ['Banco de origem', 'Para compra de dívida, refin e portabilidade.'],
  ['Contrato de origem', ''],
  ['Saldo devedor', ''],
  ['Telefone', ''],
  ['E-mail', ''],
  ['Observação', 'Vai para o histórico quando a etapa muda.'],
  // Client record (optional): fills only empty fields of the client; a bad value is skipped, never refusing the contract.
  ['WhatsApp', 'Ficha do cliente. Com DDD.'],
  ['Data de nascimento', 'Ficha do cliente. dd/mm/aaaa.'],
  ['Sexo', 'Ficha do cliente.'],
  ['Estado civil', 'Ficha do cliente.'],
  ['Naturalidade', 'Ficha do cliente. Cidade - UF.'],
  ['Nome da mãe', 'Ficha do cliente.'],
  ['Nome do pai', 'Ficha do cliente.'],
  ['RG', 'Ficha do cliente.'],
  ['RG órgão emissor', 'Ficha do cliente.'],
  ['UF do RG', 'Ficha do cliente.'],
  ['Data de expedição', 'Ficha do cliente. Data de expedição do RG.'],
  ['CEP', 'Endereço do cliente (gravado se ele ainda não tiver endereço).'],
  ['Logradouro', ''],
  ['Número', ''],
  ['Complemento', ''],
  ['Bairro', ''],
  ['Cidade', ''],
  ['UF', ''],
  ['Código do banco', 'Conta do cliente para crédito. Ex.: 001.'],
  ['Nome do banco', ''],
  ['Agência', ''],
  ['Conta', ''],
  ['Dígito da conta', ''],
  ['Tipo de conta', ''],
  ['Matrícula', 'Matrícula do cliente no convênio da tabela.'],
  ['Secretaria', 'Órgão onde o cliente trabalha.'],
]
const TEXT_COLUMNS = ['CPF *', 'Nº contrato/ADE', 'Contrato de origem', 'WhatsApp', 'Telefone', 'RG', 'CEP', 'Código do banco', 'Agência', 'Conta', 'Dígito da conta', 'Matrícula']

export async function GET(request: Request) {
  const { supabase, access, organization } = await requireAppContext()
  if (!can(access, 'propostas.create')) return new Response('Sem permissão', { status: 403 })
  const layout = CONTRACT_LAYOUTS.find(l => l.key === new URL(request.url).searchParams.get('layout')) ?? CONTRACT_LAYOUTS[0]

  const [{ data: banks }, { data: catalog }] = await Promise.all([
    supabase.from('organization_banks').select('id').eq('name', layout.bankName),
    supabase.rpc('proposal_catalog', { p_org: organization.id, p_keep: null }),
  ])
  const bankId = (banks ?? [])[0]?.id as string | undefined
  const tables = [...new Set(((catalog ?? []) as { bank_id: string; table_name: string }[]).filter(r => r.bank_id === bankId).map(r => r.table_name))]
    .sort((a, b) => a.localeCompare(b, 'pt-BR'))

  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet(`Contratos ${layout.label}`)
  ws.addRow(COLUMNS.map(([h]) => h))
  const head = ws.getRow(1)
  head.height = 30
  COLUMNS.forEach(([h, tip], i) => {
    const cell = head.getCell(i + 1)
    cell.font = { bold: true, color: { argb: 'FFFFFFFF' } }
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: h.endsWith('*') ? 'FF1F4E78' : 'FF8EA9C1' } }
    cell.alignment = { vertical: 'middle', horizontal: 'center', wrapText: true }
    if (tip) cell.note = tip
  })
  ws.columns = COLUMNS.map(([h]) => ({ width: Math.max(14, h.length + 4) }))
  ws.getColumn(3).width = 44
  ws.views = [{ state: 'frozen', ySplit: 1 }]
  // Text columns stay text, so Excel keeps the zeros of a CPF or an ADE.
  COLUMNS.forEach(([h], i) => { if (TEXT_COLUMNS.includes(h)) ws.getColumn(i + 1).numFmt = '@' })
  const col = (h: string) => COLUMNS.findIndex(([x]) => x === h) + 1
  const list = (col: number, formula: string) => {
    for (let r = 2; r <= 501; r++) ws.getCell(r, col).dataValidation = { type: 'list', allowBlank: true, formulae: [formula] }
  }
  list(col('Tipo'), '"novo,refin,compra,portabilidade"')
  list(col('Etapa'), '"fila,digitando,enviada,pendencia,aprovada,paga,recusada,cancelada"')
  list(col('Sexo'), '"masculino,feminino"')
  list(col('Estado civil'), '"solteiro,casado,união estável,divorciado,separado,viúvo"')
  list(col('Tipo de conta'), '"corrente,poupança,salário,pagamento"')

  const ts = wb.addWorksheet('Tabelas')
  ts.addRow([`Tabelas ${layout.bankName} em vigor`])
  ts.getRow(1).font = { bold: true }
  for (const t of tables) ts.addRow([t])
  ts.getColumn(1).width = 52
  if (tables.length) list(col('Tabela *'), `Tabelas!$A$2:$A$${tables.length + 1}`)

  const buf = await wb.xlsx.writeBuffer()
  return new Response(buf as ArrayBuffer, {
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="modelo-contratos-${layout.key}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
