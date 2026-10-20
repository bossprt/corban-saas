import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { STAGE_TONE, isLeadStage, stageLabel } from '@/lib/crm'
import { leadOwners } from '@/lib/crm.server'
import { assignLeads, releaseLeads } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'
const DAY_OPTIONS = [2, 3, 5, 7, 15, 30]
const since = (iso: string) => {
  const d = Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000)
  return d <= 1 ? 'há 1 dia' : `há ${d} dias`
}

type Idle = { lead_id: string; full_name: string; status: string; owner_user_id: string; campaign_id: string | null; last_activity_at: string; open_tasks: number }

// Idle leads (supervisor): open leads with a seller and no movement for N days and no task ahead. Pass them to another
// seller or send them back to the queue.
export default async function IdleLeadsPage({ searchParams }: { searchParams: Promise<{ dias?: string }> }) {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'leads.approve')) redirect('/app/crm')
  const sp = await searchParams
  const days = DAY_OPTIONS.includes(Number(sp.dias)) ? Number(sp.dias) : 3
  const [{ data }, people, { data: campaigns }] = await Promise.all([
    supabase.rpc('idle_leads', { p_org: organization.id, p_days: days }),
    leadOwners(supabase),
    supabase.from('sales_campaigns').select('id,name'),
  ])
  const rows = (data ?? []) as Idle[]
  const name = new Map(people.map(p => [p.id, p.name]))
  const campaignName = new Map((campaigns ?? []).map(c => [c.id, c.name]))
  const here = `/app/crm/parados?dias=${days}`

  return (
    <section>
      <Link href="/app/crm" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendas</Link>
      <PageHeader title="Leads parados" description="Leads em aberto com vendedor, sem nenhuma movimentação no período e sem tarefa marcada para frente." />

      <form className="mb-4 flex flex-wrap items-end gap-2">
        <label className={label}>Sem movimento há mais de
          <select name="dias" defaultValue={String(days)} className="field mt-1.5">{DAY_OPTIONS.map(d => <option key={d} value={d}>{d} dias</option>)}</select>
        </label>
        <button className="inline-flex h-10 items-center rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted">Ver</button>
      </form>

      <form>
        <input type="hidden" name="back" value={here} />
        <Card className="overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] text-left text-sm">
              <thead className="bg-surface-muted text-xs font-semibold text-muted">
                <tr><th className="w-8 px-4 py-2.5"><span className="sr-only">Marcar</span></th><th className="px-4 py-2.5">Lead</th><th className="px-4 py-2.5">Etapa</th><th className="px-4 py-2.5">Vendedor</th><th className="px-4 py-2.5">Último movimento</th></tr>
              </thead>
              <tbody>
                {rows.length === 0 && <tr><td colSpan={5} className="px-4 py-6 text-center text-muted">Nenhum lead parado há mais de {days} dias.</td></tr>}
                {rows.map(r => (
                  <tr key={r.lead_id} className="border-t border-line">
                    <td className="px-4 py-2.5"><input type="checkbox" name="lead_ids" value={r.lead_id} aria-label={`Marcar ${r.full_name}`} className="accent-[var(--brand)]" /></td>
                    <td className="px-4 py-2.5"><Link href={`/app/crm?lead=${r.lead_id}`} className="font-medium text-ink hover:underline">{r.full_name}</Link>{r.campaign_id && <span className="block text-xs text-muted">{campaignName.get(r.campaign_id)}</span>}</td>
                    <td className="px-4 py-2.5"><Badge tone={isLeadStage(r.status) ? STAGE_TONE[r.status] : 'neutral'}>{stageLabel(r.status)}</Badge></td>
                    <td className="px-4 py-2.5 text-ink-soft">{name.get(r.owner_user_id) ?? 'Vendedor'}</td>
                    <td className="px-4 py-2.5 text-ink-soft">{since(r.last_activity_at)}{r.open_tasks > 0 && <span className="block text-xs text-[#B91C1C]">{r.open_tasks} tarefa(s) atrasada(s)</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
        {rows.length > 0 && (
          <div className="mt-4 flex flex-wrap items-end gap-3">
            <label className={label}>Passar os marcados para
              <select name="owner_user_id" defaultValue="" className="field mt-1.5 min-w-[220px]">
                <option value="" disabled>Escolha o vendedor</option>
                {people.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </label>
            <button formAction={assignLeads} className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Passar para o vendedor</button>
            <button formAction={releaseLeads} className="inline-flex h-10 items-center rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted">Devolver para a fila</button>
          </div>
        )}
      </form>
    </section>
  )
}
