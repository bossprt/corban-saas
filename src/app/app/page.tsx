import Link from 'next/link'
import { ChevronRight } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { redirect } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { actionItems } from '@/lib/action-center'
import { isPortalUser } from '@/lib/portal'

type Counted = { count: number | null; error: unknown }
// A failed or unavailable query is shown as "indisponível", never as a misleading zero.
const num = (r: Counted) => (r.error ? 'indisponível' : String(r.count ?? 0))
// Timestamps are computed per request on the server; kept out of the component body to stay a pure render.
const isoAgo = (ms: number) => new Date(Date.now() - ms).toISOString()

export default async function DashboardPage() {
  const { supabase, organization, membership, user, access, modules } = await requireAppContext()
  if (isPortalUser(access?.roleKey, modules)) redirect('/app/portal')
  // An operator sees THEIR own leads and proposals first; supervision roles see the whole organization.
  const mine = membership.role === 'agent'
  const own = <T,>(q: T): T => (mine ? (q as unknown as { eq: (c: string, v: string) => T }).eq('created_by', user.id) : q)
  const head = { count: 'exact', head: true } as const
  const staleCutoff = isoAgo(2 * 24 * 3600 * 1000)
  const [staleLeads, draftProposals, overdueCases, leads, customers, proposals, jobs, cases] = await Promise.all([
    own(supabase.from('leads').select('*', head).eq('status', 'new').lt('created_at', staleCutoff)),
    own(supabase.from('proposals_v2').select('*', head).eq('status', 'draft')),
    supabase.from('operational_cases').select('*', head).not('canonical_state', 'in', '("paid","cancelled","rejected")').lt('due_at', isoAgo(0)),
    own(supabase.from('leads').select('*', head).in('status', ['new', 'contacted', 'qualified'])),
    supabase.from('clients').select('*', head).is('deleted_at', null),
    own(supabase.from('proposals_v2').select('*', head)),
    supabase.from('digitization_jobs').select('*', head).in('status', ['queued', 'assigned', 'in_progress', 'blocked']),
    supabase.from('operational_cases').select('*', head).not('canonical_state', 'in', '("paid","cancelled","rejected")'),
  ])
  const cards: [string, string, string, string][] = [
    [mine ? 'Meus leads em aberto' : 'Leads em aberto', num(leads), '/app/leads', 'novos, em contato ou qualificados'],
    ['Clientes ativos', num(customers), '/app/clientes', ''],
    [mine ? 'Minhas propostas' : 'Propostas', num(proposals), '/app/propostas', mine ? 'propostas criadas por você' : 'todas as propostas da empresa'],
    ['Casos na operação', num(cases), '/app/operacao', 'em andamento na esteira'],
    ['Fila de digitação', num(jobs), '/app/operacao', ''],
  ]
  const attention = actionItems(membership.role, {
    staleLeads: staleLeads.error ? null : staleLeads.count, draftProposals: draftProposals.error ? null : draftProposals.count, overdueCases: overdueCases.error ? null : overdueCases.count,
  })
  return <section>
    <PageHeader title="Visão geral" description={organization?.name} />
    <Card className="mb-4">
      <CardHeader title={<span className="flex items-center gap-2">Precisa da sua atenção {attention.length > 0 && <Badge tone="diverged">{attention.length}</Badge>}</span>} />
      {attention.length === 0
        ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nada pendente agora.</p>
        : <ul className="mt-3">{attention.map(a => (
          <li key={a.key}>
            <Link href={a.href} className="flex items-center justify-between gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
              <span><span className="block text-sm font-medium text-ink">{a.label}</span><span className="block text-[13px] text-ink-soft">{a.hint}</span></span>
              <span className="flex items-center gap-2"><strong className="num text-lg text-[#92400E]">{a.count}</strong><ChevronRight size={16} aria-hidden className="text-muted" /></span>
            </Link>
          </li>
        ))}</ul>}
    </Card>
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
      {cards.map(([label, value, href, hint]) => (
        <Link href={href} key={label} className="flex flex-col gap-1.5 rounded-[14px] border border-line bg-surface px-5 py-4 hover:border-line-strong hover:bg-surface-muted">
          <span className="text-[13px] font-medium text-muted">{label}</span>
          <span className={value === 'indisponível' ? 'text-base font-semibold text-[#92400E]' : 'num text-[28px] font-semibold tracking-tight text-ink'}>{value}</span>
          {hint && <span className="text-[13px] text-ink-soft">{hint}</span>}
        </Link>
      ))}
    </div>
    <p className="mt-6 text-xs text-muted">Os números desta tela vêm direto da sua empresa e respeitam o seu perfil de acesso.</p>
  </section>
}
