import { notFound } from 'next/navigation'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import type { AccountReport } from '@/lib/payout/batches'
import { PrintBar } from '../PrintBar'
import { PRINT_CSS } from '../sheets'
import { PersonSheet } from '../PersonSheet'

const DATE = /^\d{4}-\d{2}-\d{2}$/
const MAX_PEOPLE = 200

// Commissions paid by seller (owner, 21/10/2026): one seller, or "todas" = one sheet per person paid in the period,
// ready to print and hand to each. Finance only.
export default async function PrintSellersReport({ searchParams }: { searchParams: Promise<{ conta?: string; de?: string; ate?: string }> }) {
  const sp = await searchParams
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'repasse.view')) notFound()
  const from = DATE.test(sp.de ?? '') ? sp.de! : null
  const to = DATE.test(sp.ate ?? '') ? sp.ate! : null
  if (!from || !to || to < from) notFound()

  let accounts: string[]
  if (sp.conta === 'todas') {
    const { data } = await supabase.from('payouts').select('account_id').eq('status', 'paid').gte('paid_on', from).lte('paid_on', to).limit(5000)
    accounts = [...new Set((data ?? []).map(p => p.account_id as string))].slice(0, MAX_PEOPLE)
  } else if (isUuid(sp.conta ?? '')) accounts = [sp.conta!]
  else notFound()

  const reports = (await Promise.all(accounts.map(async id => {
    const { data } = await supabase.rpc('payout_account_report', { p_account: id, p_from: from, p_to: to })
    return data as AccountReport | null
  }))).filter((r): r is AccountReport => !!r).sort((a, b) => a.holder.name.localeCompare(b.holder.name, 'pt-BR'))

  return (
    <div className="sheets">
      <style>{PRINT_CSS}</style>
      <PrintBar back="/app/relatorios/comissoes-vendedor">
        <span className="text-sm text-muted">{reports.length} vendedor(es) · {from.split('-').reverse().join('/')} a {to.split('-').reverse().join('/')}</span>
      </PrintBar>
      {reports.length === 0 && <p className="print-hide text-center text-sm text-muted">Nenhum pagamento no período.</p>}
      {reports.map((r, i) => <PersonSheet key={i} r={r} page={reports.length > 1 ? `${i + 1} de ${reports.length}` : undefined} />)}
    </div>
  )
}
