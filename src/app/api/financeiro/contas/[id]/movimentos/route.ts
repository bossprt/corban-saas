import type { NextRequest } from 'next/server'
import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { FIN_SOURCE_LABEL } from '@/lib/finance/labels'
import { loadMovements } from '@/lib/finance/movements'
import { isUuid } from '@/lib/team'

export const dynamic = 'force-dynamic'

const br = (iso: string) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`

// The movements of one company bank account as a spreadsheet, the same rows as the screen, to compare with the bank.
export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return new Response('Sem permissão.', { status: 403 })
  const { id } = await params
  if (!isUuid(id)) return new Response('Conta inválida.', { status: 400 })
  const m = await loadMovements(supabase, id, req.nextUrl.searchParams.get('de') ?? undefined, req.nextUrl.searchParams.get('ate') ?? undefined)
  if (!m) return new Response('Conta não encontrada.', { status: 404 })

  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet('Movimentações')
  ws.columns = [
    { header: 'Data', width: 12 }, { header: 'Descrição', width: 48 }, { header: 'Fornecedor / cliente', width: 30 }, { header: 'Origem', width: 18 },
    { header: 'Entrada (R$)', width: 14 }, { header: 'Saída (R$)', width: 14 }, { header: 'Saldo (R$)', width: 14 },
  ]
  ws.getRow(1).font = { bold: true }
  ws.addRow([br(m.from), 'Saldo no início do período', '', '', null, null, Number(m.startBalance)])
  for (const r of m.rows) ws.addRow([
    br(r.settled_on), r.description, r.counterpart ?? '', FIN_SOURCE_LABEL[r.source] ?? r.source,
    r.amountIn ? Number(r.amountIn) : null, r.amountOut ? Number(r.amountOut) : null, Number(r.balance),
  ])
  ws.addRow([br(m.to), 'Totais e saldo no fim do período', '', '', Number(m.totalIn), Number(m.totalOut), Number(m.endBalance)]).font = { bold: true }
  for (const c of [5, 6, 7]) ws.getColumn(c).numFmt = '#,##0.00'
  ws.views = [{ state: 'frozen', ySplit: 1 }]

  const name = m.bank.label.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase() || 'conta'
  const buffer = await wb.xlsx.writeBuffer()
  return new Response(buffer as ArrayBuffer, {
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="movimentacoes-${name}-${m.from}-a-${m.to}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
