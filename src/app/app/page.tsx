import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'

type Counted = { count: number | null; error: unknown }
// A failed or unavailable query is shown as "indisponível", never as a misleading zero.
const num = (r: Counted) => (r.error ? 'indisponível' : String(r.count ?? 0))
const brl = (n: number) => `R$ ${n.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}`

export default async function DashboardPage() {
  const { supabase, organization, membership } = await requireAppContext()
  const canSeeFinance = canViewCommission(membership.role)
  const canSeeIntegrations = atLeast(membership.role, 'supervisor')
  const head = { count: 'exact', head: true } as const
  const [leads, customers, proposals, jobs, cases, runs, divergences, reviews, expected, received, reversals] = await Promise.all([
    supabase.from('leads').select('*', head).in('status', ['new', 'contacted', 'qualified']),
    supabase.from('clients').select('*', head).is('deleted_at', null),
    supabase.from('proposals_v2').select('*', head),
    supabase.from('digitization_jobs').select('*', head).in('status', ['queued', 'assigned', 'in_progress', 'blocked']),
    supabase.from('operational_cases').select('*', head).not('canonical_state', 'in', '("paid","cancelled","rejected")'),
    canSeeIntegrations ? supabase.from('integration_runs').select('*', head).eq('status', 'failed').eq('terminal', true) : Promise.resolve({ count: null, error: null }),
    supabase.from('financial_reconciliation_cases').select('*', head).in('status', ['divergent', 'human_required']),
    supabase.from('import_match_candidates').select('*', head).eq('status', 'human_required'),
    supabase.from('financial_events').select('amount').eq('event_type', 'commission_expected'),
    supabase.from('financial_events').select('amount').eq('event_type', 'payment_received'),
    supabase.from('financial_events').select('amount,metadata').eq('event_type', 'reversal'),
  ])
  const cards: [string, string, string, string][] = [
    ['Leads em aberto', num(leads), '/app/leads', 'novos, em contato ou qualificados'],
    ['Clientes ativos', num(customers), '/app/clientes', ''],
    ['Propostas', num(proposals), '/app/propostas', 'todas as propostas da organização'],
    ['Casos na operação', num(cases), '/app/operacao', 'em andamento na esteira'],
    ['Fila de digitação', num(jobs), '/app/operacao', ''],
  ]
  const expectedTotal = (expected.data ?? []).reduce((s, x) => s + Number(x.amount), 0)
  // Reversals are compensating events: they net against the bucket of the event they reverse.
  const reversedOf = (type: string) => (reversals.data ?? []).filter(r => (r.metadata as { reversed_event_type?: string } | null)?.reversed_event_type === type).reduce((s, x) => s + Number(x.amount), 0)
  const expectedNet = expectedTotal - reversedOf('commission_expected')
  const receivedTotal = (received.data ?? []).reduce((s, x) => s + Number(x.amount), 0) - reversedOf('payment_received')
  const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-slate-700'
  return <section>
    <div className="mb-8"><p className="text-sm text-emerald-400">Piloto</p><h1 className="mt-1 text-3xl font-semibold">Visão geral</h1><p className="mt-2 text-slate-400">{organization?.name}</p></div>
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">{cards.map(([label, value, href, hint]) => <Link href={href} key={label} className={card}><div className="text-sm text-slate-400">{label}</div><div className={`mt-3 font-semibold ${value === 'indisponível' ? 'text-base text-amber-300' : 'text-3xl'}`}>{value}</div>{hint && <div className="mt-1 text-xs text-slate-500">{hint}</div>}</Link>)}</div>
    <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {canSeeIntegrations && <Link href="/app/integracoes" className={card}><div className="text-sm text-slate-400">Integrações que precisam de atenção</div><div className={`mt-3 font-semibold ${runs.error ? 'text-base text-amber-300' : 'text-3xl'}`}>{num(runs)}</div><div className="mt-1 text-xs text-slate-500">execuções com falha definitiva</div></Link>}
      {canSeeFinance && <Link href="/app/financeiro" className={card}><div className="text-sm text-slate-400">Conciliações pendentes</div><div className="mt-3 text-3xl font-semibold">{num(divergences)}</div><div className="mt-1 text-xs text-slate-500">divergentes ou aguardando decisão</div></Link>}
      <Link href="/app/importacoes" className={card}><div className="text-sm text-slate-400">Revisões humanas de importação</div><div className="mt-3 text-3xl font-semibold">{num(reviews)}</div></Link>
    </div>
    {canSeeFinance && <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <Link href="/app/financeiro" className={card}><div className="text-sm text-slate-400">Comissão esperada</div><div className="mt-3 text-2xl font-semibold">{brl(expectedNet)}</div><div className="mt-1 text-xs text-slate-500">previsão; não é receita</div></Link>
      <Link href="/app/financeiro" className={card}><div className="text-sm text-slate-400">Recebido comprovado</div><div className="mt-3 text-2xl font-semibold">{brl(receivedTotal)}</div><div className="mt-1 text-xs text-slate-500">somente com evidência validada</div></Link>
    </div>}
    <div className="mt-8 rounded-2xl border border-slate-800 bg-slate-900 p-6"><h2 className="font-semibold">Fluxo operacional</h2><p className="mt-2 text-sm leading-6 text-slate-400">Lead → Cliente → Simulação → Proposta → Documentos → Operação → Integrações → Financeiro → Conciliação. Os números desta tela vêm direto da sua organização e respeitam o seu perfil de acesso.</p></div>
  </section>
}
