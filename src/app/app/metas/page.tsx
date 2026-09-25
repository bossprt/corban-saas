import { Card, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canManageTeam } from '@/lib/rbac'
import { memberEmails } from '@/lib/team.server'
import { saveDistribution, saveGoal } from './actions'

const brl = (v: number | string) => Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
const MODE_LABEL: Record<string, string> = { round_robin: 'Rodízio entre quem recebe leads', queue: 'Fila aberta (quem pegar primeiro)', manual: 'Manual (supervisor distribui)' }
const thisMonth = () => new Date().toISOString().slice(0, 7)

// Goals (paid released amount per month) and lead distribution. Supervisors set goals for people they can see;
// administrators and managers choose how leads from the API are distributed.
export default async function GoalsPage({ searchParams }: { searchParams: Promise<{ mes?: string }> }) {
  const { supabase, organization, membership } = await requireAppContext()
  const sp = await searchParams
  const month = /^\d{4}-\d{2}$/.test(sp.mes ?? '') ? sp.mes! : thisMonth()
  const [{ data: progress }, { data: members }, { data: settings }] = await Promise.all([
    supabase.rpc('goal_progress', { p_org: organization.id, p_month: `${month}-01` }),
    supabase.from('organization_memberships').select('id,user_id,status,receives_leads').eq('status', 'active'),
    supabase.from('organization_lead_settings').select('distribution').maybeSingle(),
  ])
  const rows = (progress ?? []) as { user_id: string; target_amount: string; paid_amount: string; paid_count: number }[]
  const byUser = new Map(rows.map(r => [r.user_id, r]))
  const visibleMembers = (members ?? []).filter(m => byUser.has(m.user_id) || atLeast(membership.role, 'supervisor'))
  const emails = await memberEmails(visibleMembers.map(m => m.user_id))
  const canSetGoals = atLeast(membership.role, 'supervisor')

  return (
    <section>
      <PageHeader title="Metas" description="Meta mensal por pessoa, medida pelo valor liberado dos contratos pagos no mês." />
      <form className="mb-4 flex items-end gap-2">
        <label className="text-[13px] font-medium text-ink-soft">Mês<input type="month" name="mes" defaultValue={month} className="field mt-1.5" /></label>
        <button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted">Ver</button>
      </form>

      <Card className="overflow-hidden">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-4 py-2.5">Pessoa</th><th className="px-4 py-2.5 text-right">Pago no mês</th><th className="px-4 py-2.5 text-right">Contratos</th><th className="px-4 py-2.5">Progresso</th>{canSetGoals && <th className="px-4 py-2.5">Meta</th>}</tr></thead>
          <tbody>
            {visibleMembers.map(m => {
              const r = byUser.get(m.user_id)
              const target = Number(r?.target_amount ?? 0)
              const paid = Number(r?.paid_amount ?? 0)
              const pct = target > 0 ? Math.min(100, Math.round((paid / target) * 100)) : 0
              return (
                <tr key={m.id} className="border-t border-line">
                  <td className="px-4 py-2.5 text-ink">{emails.get(m.user_id) ?? 'Usuário'}</td>
                  <td className="num px-4 py-2.5 text-right text-ink">{brl(r?.paid_amount ?? 0)}</td>
                  <td className="num px-4 py-2.5 text-right text-ink-soft">{r?.paid_count ?? 0}</td>
                  <td className="px-4 py-2.5">
                    {target > 0 ? (
                      <div className="flex items-center gap-2">
                        <div className="h-2 w-40 overflow-hidden rounded-full bg-[#F3F1EC]"><div className="h-2 rounded-full bg-brand" style={{ width: `${pct}%` }} /></div>
                        <span className="num text-xs text-muted">{pct}% de {brl(target)}</span>
                      </div>
                    ) : <span className="text-xs text-muted">Sem meta</span>}
                  </td>
                  {canSetGoals && (
                    <td className="px-4 py-2.5">
                      <form action={saveGoal} className="flex items-center gap-2">
                        <input type="hidden" name="user_id" value={m.user_id} />
                        <input type="hidden" name="month" value={month} />
                        <input name="target" inputMode="decimal" defaultValue={target ? String(r?.target_amount).replace('.', ',') : ''} placeholder="250.000,00" aria-label="Meta do mês" className="field h-9 w-36 py-1" />
                        <button className="h-9 rounded-lg border border-line px-3 text-xs hover:bg-surface-muted">Salvar</button>
                      </form>
                    </td>
                  )}
                </tr>
              )
            })}
            {visibleMembers.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-muted">Nenhuma meta para mostrar.</td></tr>}
          </tbody>
        </table>
      </Card>

      {canManageTeam(membership.role) && (
        <Card className="mt-6">
          <CardHeader title="Distribuição de leads da API" />
          <form action={saveDistribution} className="space-y-4 p-5 pt-3 text-sm">
            <fieldset className="space-y-2">
              <legend className="mb-1 text-[13px] font-medium text-ink-soft">Como os leads novos chegam à equipe</legend>
              {Object.entries(MODE_LABEL).map(([k, v]) => (
                <label key={k} className="flex items-center gap-2 text-ink"><input type="radio" name="distribution" value={k} defaultChecked={(settings?.distribution ?? 'manual') === k} className="accent-[var(--brand)]" />{v}</label>
              ))}
            </fieldset>
            <fieldset>
              <legend className="mb-1 text-[13px] font-medium text-ink-soft">Quem recebe leads no rodízio</legend>
              <div className="grid gap-1 sm:grid-cols-2">
                {(members ?? []).map(m => (
                  <label key={m.id} className="flex items-center gap-2 text-ink">
                    <input type="hidden" name="membership_id" value={m.id} />
                    <input type="checkbox" name="receives" value={m.id} defaultChecked={m.receives_leads} className="accent-[var(--brand)]" />{emails.get(m.user_id) ?? 'Usuário'}
                  </label>
                ))}
              </div>
            </fieldset>
            <button className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Salvar distribuição</button>
          </form>
        </Card>
      )}
    </section>
  )
}
