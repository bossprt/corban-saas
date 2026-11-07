import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { isUuid } from '@/lib/team'
import { PAYOUT_STATUS_LABEL } from '@/lib/payout/format'
import { batchItemLabel, breakdownItemLabel, type BatchDetail } from '@/lib/payout/batches'
import { batchFooter } from '@/lib/payout/breakdown'
import { batchTotals } from '@/lib/payout/pay-safety'

export const dynamic = 'force-dynamic'

// One payment batch as a spreadsheet: one row per contract paid (or per person when the payment has no contract), with
// the person, the amount paid and the situation. Money goes in as the database's decimal text, read once by Excel.
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) return new Response('Lote inválido.', { status: 400 })
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'repasse.view')) return new Response('Sem permissão.', { status: 403 })
  const { data, error } = await supabase.rpc('payout_batch_detail', { p_batch: id })
  if (error || !data) return new Response('Lote não encontrado.', { status: 404 })
  const b = data as BatchDetail

  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet('Lote')
  ws.columns = [
    { header: 'Pagamento dia', width: 14 }, { header: 'Pessoa', width: 34 }, { header: 'ADE', width: 14 }, { header: 'Cliente', width: 34 },
    { header: 'Banco', width: 20 }, { header: 'Convênio', width: 22 }, { header: 'Produto', width: 18 }, { header: 'Liberado ao cliente (R$)', width: 20 }, { header: 'Pago ao cliente em', width: 16 },
    { header: 'Comissão do contrato / lançamento (R$)', width: 26 }, { header: 'Valor pago à pessoa (R$)', width: 22 }, { header: 'Pago em parte', width: 14 }, { header: 'Situação', width: 18 },
    { header: 'Comprovante', width: 20 }, { header: 'Conta que pagou', width: 24 },
  ]
  ws.getRow(1).font = { bold: true }
  const day = `${b.paid_on.slice(8, 10)}/${b.paid_on.slice(5, 7)}/${b.paid_on.slice(0, 4)}`
  const br = (d: string | null | undefined) => (d ? `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}` : '')
  for (const l of b.lines) {
    const status = PAYOUT_STATUS_LABEL[l.status] ?? l.status
    // One row per contract, then one per other entry (vale, bônus, desconto, saldo anterior...) of this payment.
    const rows: unknown[][] = [
      ...l.contracts.map(c => [batchItemLabel(c), c.client ?? '', c.bank ?? '', c.agreement ?? '', c.product ?? '', c.released ? Number(c.released) : null, br(c.paid_to_client_on), Number(c.amount), c.partial ? 'Sim' : '']),
      ...(l.others ?? []).map(o => [breakdownItemLabel(o), [o.description, br(o.effective_on)].filter(Boolean).join(' · '), '', '', '', null, '', Number(o.amount), o.partial ? 'Sim' : '']),
    ]
    if (!rows.length) rows.push(['', '', '', '', '', null, '', null, ''])
    rows.forEach((r, i) => ws.addRow([day, l.holder, ...r.slice(0, 8), i === 0 ? Number(l.amount) : null, r[8], status, b.payment_reference ?? '', b.bank_accounts ?? '']))
  }
  ws.addRow([])
  // Footer split (owner, 06/11/2026): Soma dos contratos, each other entry, Total pago. Only what was paid; undone apart.
  const totals = batchTotals(b.lines)
  const foot = batchFooter(b.lines)
  ws.addRow(['Soma dos contratos', '', '', '', '', '', '', null, '', Number(foot.contractsTotal)]).font = { bold: true }
  for (const o of foot.others) ws.addRow(['Outros lançamentos', o.holder, o.label, o.description ?? '', '', '', '', null, '', Number(o.amount)])
  if (foot.others.length) ws.addRow(['Total de outros lançamentos', '', '', '', '', '', '', null, '', Number(foot.othersTotal)])
  if (foot.hasDifference) ws.addRow(['Diferença não explicada', '', '', '', '', '', '', null, '', Number(foot.difference)]).font = { bold: true, color: { argb: 'FF991B1B' } }
  ws.addRow(['Total pago', '', '', '', '', '', '', null, '', null, Number(totals.paidTotal)]).font = { bold: true }
  if (totals.undoneCount) ws.addRow([`Desfeito (${totals.undoneCount}, não entra no total)`, '', '', '', '', '', '', null, '', null, Number(totals.undoneTotal)])
  for (const c of [8, 10, 11]) ws.getColumn(c).numFmt = '#,##0.00'
  ws.getColumn(3).numFmt = '@'
  ws.views = [{ state: 'frozen', ySplit: 1 }]
  const buffer = await wb.xlsx.writeBuffer()
  return new Response(buffer as ArrayBuffer, {
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="lote-pagamento-${b.paid_on}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
