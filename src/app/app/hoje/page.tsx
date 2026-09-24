import Link from 'next/link'
import { ArrowRight, FilePlus2, UserPlus, UserRoundPlus } from 'lucide-react'
import { requireAppContext } from '@/lib/appContext'
import { loadAttention } from '@/lib/attention.server'
import { isSeverity, SEVERITY_LABEL, SEVERITY_ORDER, type Severity } from '@/lib/attention-rules'
import { proposalStatusLabel } from '@/lib/operational'
import { atLeast } from '@/lib/rbac'
import { Badge, ButtonLink, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'

const SEVERITY_TONE: Record<Severity, Tone> = { critical: 'reversed', high: 'diverged', medium: 'paid-out', low: 'neutral' }
const LEAD_STATUS: Record<string, string> = { new: 'Novo', contacted: 'Em contato', qualified: 'Qualificado' }
const OPEN_PROPOSAL = ['draft', 'documents_pending', 'ready_for_digitization', 'digitization', 'submitted', 'approved']

const brl = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))
const monthStart = () => `${new Date().toISOString().slice(0, 7)}-01`
const daysSince = (iso: string) => Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000))
const ago = (iso: string) => {
  const d = daysSince(iso)
  return d === 0 ? 'hoje' : d === 1 ? 'há 1 dia' : `há ${d} dias`
}

// "Hoje": the first screen of the day for every profile. What needs action now (attention rules for the role),
// the caller's own open leads and proposals, and the shortcuts to start work.
export default async function TodayPage() {
  const ctx = await requireAppContext()
  const { supabase, user, membership } = ctx

  const [attention, leads, proposals, goals] = await Promise.all([
    loadAttention(ctx),
    supabase.from('leads').select('id,full_name,status,channel,created_at').eq('owner_user_id', user.id).in('status', ['new', 'contacted', 'qualified']).order('created_at', { ascending: true }).limit(6),
    supabase.from('proposals_v2').select('id,status,requested_amount,updated_at,customer_snapshot').eq('created_by', user.id).in('status', OPEN_PROPOSAL).order('updated_at', { ascending: true }).limit(6),
    supabase.rpc('goal_progress', { p_org: ctx.organization.id, p_month: monthStart() }),
  ])
  const myGoal = ((goals.data ?? []) as { user_id: string; target_amount: string; paid_amount: string; paid_count: number }[]).find(g => g.user_id === user.id)
  const goalTarget = Number(myGoal?.target_amount ?? 0)
  const goalPaid = Number(myGoal?.paid_amount ?? 0)
  const goalPct = goalTarget > 0 ? Math.min(100, Math.round((goalPaid / goalTarget) * 100)) : 0

  const open = attention.items
    .filter(i => i.status === 'open')
    .sort((a, b) => SEVERITY_ORDER.indexOf(isSeverity(a.severity) ? a.severity : 'low') - SEVERITY_ORDER.indexOf(isSeverity(b.severity) ? b.severity : 'low'))
  const weekday = new Date().toLocaleDateString('pt-BR', { weekday: 'long', day: 'numeric', month: 'long' })
  const today = weekday.charAt(0).toUpperCase() + weekday.slice(1)
  const firstName = (user.user_metadata?.full_name as string | undefined)?.split(' ')[0]

  return (
    <section>
      <PageHeader
        title={firstName ? `Olá, ${firstName}` : 'Hoje'}
        description={today}
        actions={
          <>
            <ButtonLink href="/app/leads" variant="secondary" size="md"><UserPlus size={16} aria-hidden />Novo lead</ButtonLink>
            <ButtonLink href="/app/clientes" variant="secondary" size="md"><UserRoundPlus size={16} aria-hidden />Novo cliente</ButtonLink>
            <ButtonLink href="/app/simulacoes" size="md"><FilePlus2 size={16} aria-hidden />Nova proposta</ButtonLink>
          </>
        }
      />

      {goalTarget > 0 && (
        <Card className="mb-4 p-5">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <span className="text-sm font-medium text-ink-soft">Meta do mês</span>
            <span className="num text-sm text-muted">{goalPct}% · {myGoal?.paid_count ?? 0} contrato(s) pago(s)</span>
          </div>
          <div className="num mt-1 text-2xl font-semibold text-ink">{brl(goalPaid)} <span className="text-base font-normal text-muted">de {brl(goalTarget)}</span></div>
          <div className="mt-3 h-2 overflow-hidden rounded-full bg-[#F3F1EC]"><div className="h-2 rounded-full bg-brand" style={{ width: `${goalPct}%` }} /></div>
        </Card>
      )}

      <div className="grid gap-4 lg:grid-cols-[1.4fr_1fr]">
        <Card>
          <CardHeader
            title={<span className="flex items-center gap-2">Precisa de atenção {open.length > 0 && <Badge tone={open.some(i => i.severity === 'critical') ? 'reversed' : 'diverged'}>{open.length}</Badge>}</span>}
            action={atLeast(membership.role, 'supervisor') ? <Link href="/app/atencao" className="text-sm text-brand hover:text-brand-strong">Central de atenção</Link> : undefined}
          />
          <div className="px-2 pb-2 pt-2">
            {attention.notEvaluated.length > 0 && (
              <p className="mx-3 mb-2 rounded-lg bg-[#FEF3C7] px-3 py-2 text-xs text-[#92400E]">Parte dos alertas não pôde ser conferida agora. Isso não significa que está tudo em dia.</p>
            )}
            {open.length === 0 ? (
              <p className="px-3 pb-3 text-sm text-muted">Nada pendente agora.</p>
            ) : (
              <ul>
                {open.slice(0, 8).map(i => {
                  const sev = isSeverity(i.severity) ? i.severity : 'low'
                  return (
                    <li key={i.id}>
                      <Link href={i.href} className="flex items-start gap-3 rounded-lg border-t border-line px-3 py-3 first:border-t-0 hover:bg-surface-muted">
                        <Badge tone={SEVERITY_TONE[sev]} className="mt-0.5 shrink-0">{SEVERITY_LABEL[sev]}</Badge>
                        <span className="min-w-0 flex-1">
                          <span className="block text-sm font-medium text-ink">{i.title}</span>
                          <span className="block text-[13px] text-muted">{i.recommendation || i.reason}</span>
                        </span>
                        <ArrowRight size={16} className="mt-1 shrink-0 text-muted" aria-hidden />
                      </Link>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        </Card>

        <div className="grid content-start gap-4">
          <Card>
            <CardHeader title="Meus leads" action={<Link href="/app/leads" className="text-sm text-brand hover:text-brand-strong">Ver todos</Link>} />
            <ul className="px-2 pb-2 pt-2">
              {(leads.data ?? []).length === 0 && <li className="px-3 pb-3 text-sm text-muted">Nenhum lead aberto com você.</li>}
              {(leads.data ?? []).map(l => (
                <li key={l.id} className="flex items-center gap-3 border-t border-line px-3 py-2.5 first:border-t-0">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-medium text-ink">{l.full_name}</span>
                    <span className="block text-xs text-muted">{l.channel} · {ago(l.created_at)}</span>
                  </span>
                  <Badge tone={l.status === 'new' && daysSince(l.created_at) >= 2 ? 'diverged' : 'neutral'}>{LEAD_STATUS[l.status] ?? l.status}</Badge>
                </li>
              ))}
            </ul>
          </Card>

          <Card>
            <CardHeader title="Minhas propostas em andamento" action={<Link href="/app/propostas" className="text-sm text-brand hover:text-brand-strong">Esteira</Link>} />
            <ul className="px-2 pb-2 pt-2">
              {(proposals.data ?? []).length === 0 && <li className="px-3 pb-3 text-sm text-muted">Nenhuma proposta sua em andamento.</li>}
              {(proposals.data ?? []).map(p => {
                const snap = (p.customer_snapshot ?? {}) as Record<string, unknown>
                const stale = daysSince(p.updated_at) >= 4
                return (
                  <li key={p.id}>
                    <Link href={`/app/propostas/${p.id}`} className="flex items-center gap-3 rounded-lg border-t border-line px-3 py-2.5 first:border-t-0 hover:bg-surface-muted">
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-ink">{String(snap.full_name ?? snap.name ?? 'Cliente')}</span>
                        <span className="num block text-xs text-muted">{brl(p.requested_amount)} · parada {ago(p.updated_at)}</span>
                      </span>
                      <Badge tone={stale ? 'diverged' : 'neutral'}>{proposalStatusLabel(p.status).label}</Badge>
                    </Link>
                  </li>
                )
              })}
            </ul>
          </Card>
        </div>
      </div>
    </section>
  )
}
