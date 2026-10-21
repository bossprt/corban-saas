import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ArrowLeft, FileText } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'

const label = 'grid gap-1.5 text-[13px] font-medium text-ink-soft'
const today = () => new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10)
const monthStart = () => `${today().slice(0, 8)}01`

type Summary = { account_id: string; holder_name: string }

// Commissions paid by seller (owner, 21/10/2026): pick the seller (or all) and the period; the report opens ready to print.
export default async function SellerCommissionReportPage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'repasse.view')) redirect('/app/relatorios')
  const { data } = await supabase.rpc('payout_account_summaries', { p_org: organization.id })
  const people = ((data ?? []) as Summary[]).sort((a, b) => a.holder_name.localeCompare(b.holder_name, 'pt-BR'))

  return (
    <section>
      <Link href="/app/relatorios" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Relatórios</Link>
      <PageHeader title="Comissões pagas por vendedor" description="Escolha o vendedor e o período. Em &quot;Todos os vendedores&quot; sai uma folha por vendedor pago no período, pronta para imprimir e entregar." />
      <Card className="p-5">
        <form action="/imprimir/vendedores" method="get" className="flex flex-wrap items-end gap-3">
          <label className={label}>Vendedor
            <select name="conta" required defaultValue="" className="field min-w-[260px]">
              <option value="" disabled>Escolha</option>
              <option value="todas">Todos os vendedores</option>
              {people.map(p => <option key={p.account_id} value={p.account_id}>{p.holder_name}</option>)}
            </select>
          </label>
          <label className={label}>De<input type="date" name="de" required defaultValue={monthStart()} className="field" /></label>
          <label className={label}>Até<input type="date" name="ate" required defaultValue={today()} className="field" /></label>
          <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><FileText size={16} aria-hidden />Gerar relatório</button>
        </form>
      </Card>
    </section>
  )
}
