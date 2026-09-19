import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { actionItems } from '@/lib/action-center'

type Counted = { count: number | null; error: unknown }
// A failed or unavailable query is shown as "indisponível", never as a misleading zero.
const num = (r: Counted) => (r.error ? 'indisponível' : String(r.count ?? 0))
// Timestamps are computed per request on the server; kept out of the component body to stay a pure render.
const isoAgo = (ms: number) => new Date(Date.now() - ms).toISOString()
const brl = (n: number) => `R$ ${n.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}`

export default async function DashboardPage() {
  const { supabase, organization, membership, user } = await requireAppContext()
  // An operator sees THEIR own leads and proposals first; supervision roles see the whole organization.
  const mine = membership.role === 'agent'
  const own = <T,>(q: T): T => (mine ? (q as unknown as { eq: (c: string, v: string) => T }).eq('created_by', user.id) : q)
  const canSeeFinance = canViewCommission(membership.role)
  const canSeeIntegrations = atLeast(membership.role, 'supervisor')
  const head = { count: 'exact', head: true } as const
  const none = { count: null, error: null }
  const noRows = { data: [] as { amount: number | string; metadata?: unknown }[], error: null }
  const staleCutoff = isoAgo(2 * 24 * 3600 * 1000)
  const [staleLeads, draftProposals, overdueCases, leads, customers, proposals, jobs, cases, runs, divergences, reviews, expected, received, reversals] = await Promise.all([
    own(supabase.from('leads').select('*', head).eq('status', 'new').lt('created_at', staleCutoff)),
    own(supabase.from('proposals_v2').select('*', head).eq('status', 'draft')),
    supabase.from('operational_cases').select('*', head).not('canonical_state', 'in', '("paid","cancelled","rejected")').lt('due_at', isoAgo(0)),
    own(supabase.from('leads').select('*', head).in('status', ['new', 'contacted', 'qualified'])),
    supabase.from('clients').select('*', head).is('deleted_at', null),
    own(supabase.from('proposals_v2').select('*', head)),
    supabase.from('digitization_jobs').select('*', head).in('status', ['queued', 'assigned', 'in_progress', 'blocked']),
    supabase.from('operational_cases').select('*', head).not('canonical_state', 'in', '("paid","cancelled","rejected")'),
    canSeeIntegrations ? supabase.from('integration_runs').select('*', head).eq('status', 'failed').eq('terminal', true) : Promise.resolve({ count: null, error: null }),
    canSeeFinance ? supabase.from('financial_reconciliation_cases').select('*', head).in('status', ['divergent', 'human_required']) : Promise.resolve(none),
    canSeeIntegrations ? supabase.from('import_match_candidates').select('*', head).eq('status', 'human_required') : Promise.resolve(none),
    canSeeFinance ? supabase.from('financial_events').select('amount').eq('event_type', 'commission_expected') : Promise.resolve(noRows),
    canSeeFinance ? supabase.from('financial_events').select('amount').eq('event_type', 'payment_received') : Promise.resolve(noRows),
    canSeeFinance ? supabase.from('financial_events').select('amount,metadata').eq('event_type', 'reversal') : Promise.resolve(noRows),
  ])
  const cards: [string, string, string, string][] = [
    [mine ? 'Meus leads em aberto' : 'Leads em aberto', num(leads), '/app/leads', 'novos, em contato ou qualificados'],
    ['Clientes ativos', num(customers), '/app/clientes', ''],
    [mine ? 'Minhas propostas' : 'Propostas', num(proposals), '/app/propostas', mine ? 'propostas criadas por você' : 'todas as propostas da organização'],
    ['Casos na operação', num(cases), '/app/operacao', 'em andamento na esteira'],
    ['Fila de digitação', num(jobs), '/app/operacao', ''],
  ]
  const expectedTotal = (expected.data ?? []).reduce((s, x) => s + Number(x.amount), 0)
  // Reversals are compensating events: they net against the bucket of the event they reverse.
  const reversedOf = (type: string) => (reversals.data ?? []).filter(r => (r.metadata as { reversed_event_type?: string } | null)?.reversed_event_type === type).reduce((s, x) => s + Number(x.amount), 0)
  const expectedNet = expectedTotal - reversedOf('commission_expected')
  const receivedTotal = (received.data ?? []).reduce((s, x) => s + Number(x.amount), 0) - reversedOf('payment_received')
  const attention = actionItems(membership.role, {
    staleLeads: staleLeads.error ? null : staleLeads.count, draftProposals: draftProposals.error ? null : draftProposals.count, overdueCases: overdueCases.error ? null : overdueCases.count,
    failedRuns: runs.error ? null : runs.count, reconciliations: divergences.error ? null : divergences.count, importReviews: reviews.error ? null : reviews.count,
  })
  const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-slate-700'
  return <section>
    <div className="mb-8"><p className="text-sm text-emerald-400">Piloto</p><h1 className="mt-1 text-3xl font-semibold">Visão geral</h1><p className="mt-2 text-slate-400">{organization?.name}</p></div>
    <div className="mb-6 rounded-2xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Precisa da sua atenção</h2>
      {attention.length === 0 ? <p className="mt-2 text-sm text-slate-400">Nada pendente agora.</p> : <ul className="mt-3 space-y-2">{attention.map(a => <li key={a.key}><Link href={a.href} className="flex items-baseline justify-between gap-3 rounded-lg border border-slate-800 px-3 py-2 text-sm hover:border-slate-600"><span><span className="text-slate-100">{a.label}</span><span className="block text-xs text-slate-500">{a.hint}</span></span><strong className="text-lg text-amber-300">{a.count}</strong></Link></li>)}</ul>}
    </div>
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">{cards.map(([label, value, href, hint]) => <Link href={href} key={label} className={card}><div className="text-sm text-slate-400">{label}</div><div className={`mt-3 font-semibold ${value === 'indisponível' ? 'text-base text-amber-300' : 'text-3xl'}`}>{value}</div>{hint && <div className="mt-1 text-xs text-slate-500">{hint}</div>}</Link>)}</div>
    <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {canSeeIntegrations && <Link href="/app/integracoes" className={card}><div className="text-sm text-slate-400">Integrações que precisam de atenção</div><div className={`mt-3 font-semibold ${runs.error ? 'text-base text-amber-300' : 'text-3xl'}`}>{num(runs)}</div><div className="mt-1 text-xs text-slate-500">execuções com falha definitiva</div></Link>}
      {canSeeFinance && <Link href="/app/financeiro" className={card}><div className="text-sm text-slate-400">Conciliações pendentes</div><div className="mt-3 text-3xl font-semibold">{num(divergences)}</div><div className="mt-1 text-xs text-slate-500">divergentes ou aguardando decisão</div></Link>}
      {canSeeIntegrations && <Link href="/app/importacoes" className={card}><div className="text-sm text-slate-400">Revisões humanas de importação</div><div className="mt-3 text-3xl font-semibold">{num(reviews)}</div></Link>}
    </div>
    {canSeeFinance && <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <Link href="/app/financeiro" className={card}><div className="text-sm text-slate-400">Comissão esperada</div><div className="mt-3 text-2xl font-semibold">{brl(expectedNet)}</div><div className="mt-1 text-xs text-slate-500">previsão; não é receita</div></Link>
      <Link href="/app/financeiro" className={card}><div className="text-sm text-slate-400">Recebido comprovado</div><div className="mt-3 text-2xl font-semibold">{brl(receivedTotal)}</div><div className="mt-1 text-xs text-slate-500">somente com evidência validada</div></Link>
    </div>}
    <div className="mt-8 rounded-2xl border border-slate-800 bg-slate-900 p-6"><h2 className="font-semibold">Fluxo operacional</h2><p className="mt-2 text-sm leading-6 text-slate-400">Lead → Cliente → Simulação → Proposta → Documentos → Operação → Integrações → Financeiro → Conciliação. Os números desta tela vêm direto da sua organização e respeitam o seu perfil de acesso.</p></div>
  </section>
}
