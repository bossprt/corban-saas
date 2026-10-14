import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { isUuid } from '@/lib/team'
import { PAYOUT_STATUS_LABEL } from '@/lib/payout/format'
import type { BatchDetail } from '@/lib/payout/batches'

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
    { header: 'Comissão do contrato (R$)', width: 22 }, { header: 'Valor pago à pessoa (R$)', width: 22 }, { header: 'Situação', width: 18 },
    { header: 'Comprovante', width: 20 }, { header: 'Conta que pagou', width: 24 },
  ]
  ws.getRow(1).font = { bold: true }
  const day = `${b.paid_on.slice(8, 10)}/${b.paid_on.slice(5, 7)}/${b.paid_on.slice(0, 4)}`
  for (const l of b.lines) {
    const status = PAYOUT_STATUS_LABEL[l.status] ?? l.status
    const rows = l.contracts.length ? l.contracts : [null]
    rows.forEach((c, i) => ws.addRow([
      day, l.holder, c?.ade ?? '', c?.client ?? '', c ? Number(c.amount) : null, i === 0 ? Number(l.amount) : null, status,
      b.payment_reference ?? '', b.bank_accounts ?? '',
    ]))
  }
  ws.addRow([])
  ws.addRow(['Total', '', '', '', null, Number(b.total)]).font = { bold: true }
  for (const c of [5, 6]) ws.getColumn(c).numFmt = '#,##0.00'
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
