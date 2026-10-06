import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { loadPayList } from '@/lib/payout/pay-list'
import { pixCopyPaste } from '@/lib/pix/brcode'
import { formatTaxId, PIX_TYPE_LABEL } from '@/lib/sellers'

export const dynamic = 'force-dynamic'

// The pay list as a spreadsheet (owner request 06/10/2026): the same accounts and amounts as the Repasse screen, with
// the PIX key (and its copia e cola, amount included) or the TED account, for paying in the bank.
export async function GET() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'repasse.approve')) return new Response('Sem permissão.', { status: 403 })
  const lines = await loadPayList(supabase, organization.id)
  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet('A pagar')
  ws.columns = [
    { header: 'Vendedor', width: 34 }, { header: 'Valor (R$)', width: 14 }, { header: 'Forma', width: 8 }, { header: 'Tipo de chave', width: 16 },
    { header: 'Chave PIX', width: 34 }, { header: 'Banco', width: 22 }, { header: 'Agência', width: 10 }, { header: 'Conta', width: 16 },
    { header: 'Favorecido', width: 30 }, { header: 'CPF/CNPJ do favorecido', width: 22 }, { header: 'PIX copia e cola (com o valor)', width: 60 },
  ]
  ws.getRow(1).font = { bold: true }
  for (const l of lines) {
    const code = l.method === 'pix' && l.pixKey ? pixCopyPaste({ keyType: l.pixType, key: l.pixKey, amount: l.amount, name: l.holderName || l.name, city: l.city }) : null
    ws.addRow([
      l.name, Number(l.amount), l.method ? l.method.toUpperCase() : 'SEM DADOS', l.method === 'pix' ? PIX_TYPE_LABEL[l.pixType ?? ''] ?? '' : '',
      l.method === 'pix' ? l.pixKey ?? '' : '', l.method === 'ted' ? `${l.bankCode ?? ''} ${l.bankName ?? ''}`.trim() : '',
      l.method === 'ted' ? l.branch ?? '' : '', l.method === 'ted' ? `${l.accountNumber ?? ''}${l.accountDigit ? `-${l.accountDigit}` : ''}` : '',
      l.holderName ?? '', l.holderDocument ? formatTaxId(l.holderDocument) : '', code ?? '',
    ])
  }
  ws.getColumn(2).numFmt = '#,##0.00'
  for (const c of [5, 7, 8, 10, 11]) ws.getColumn(c).numFmt = '@'
  ws.views = [{ state: 'frozen', ySplit: 1 }]
  const buffer = await wb.xlsx.writeBuffer()
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  return new Response(buffer as ArrayBuffer, {
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="repasse-a-pagar-${day}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
