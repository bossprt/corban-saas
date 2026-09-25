import Link from 'next/link'
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
    [mine ? 'Minhas propostas' : 'Propostas', num(proposals), '/app/propostas', mine ? 'propostas criadas por você' : 'todas as propostas da organização'],
    ['Casos na operação', num(cases), '/app/operacao', 'em andamento na esteira'],
    ['Fila de digitação', num(jobs), '/app/operacao', ''],
  ]
  const attention = actionItems(membership.role, {
    staleLeads: staleLeads.error ? null : staleLeads.count, draftProposals: draftProposals.error ? null : draftProposals.count, overdueCases: overdueCases.error ? null : overdueCases.count,
  })
  const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-slate-700'
  return <section>
    <div className="mb-8"><h1 className="text-3xl font-semibold">Visão geral</h1><p className="mt-2 text-slate-400">{organization?.name}</p></div>
    <div className="mb-6 rounded-2xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Precisa da sua atenção</h2>
      {attention.length === 0 ? <p className="mt-2 text-sm text-slate-400">Nada pendente agora.</p> : <ul className="mt-3 space-y-2">{attention.map(a => <li key={a.key}><Link href={a.href} className="flex items-baseline justify-between gap-3 rounded-lg border border-slate-800 px-3 py-2 text-sm hover:border-slate-600"><span><span className="text-slate-100">{a.label}</span><span className="block text-xs text-slate-500">{a.hint}</span></span><strong className="text-lg text-amber-300">{a.count}</strong></Link></li>)}</ul>}
    </div>
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">{cards.map(([label, value, href, hint]) => <Link href={href} key={label} className={card}><div className="text-sm text-slate-400">{label}</div><div className={`mt-3 font-semibold ${value === 'indisponível' ? 'text-base text-amber-300' : 'text-3xl'}`}>{value}</div>{hint && <div className="mt-1 text-xs text-slate-500">{hint}</div>}</Link>)}</div>
    <p className="mt-6 text-xs text-slate-500">Os números desta tela vêm direto da sua empresa e respeitam o seu perfil de acesso.</p>
  </section>
}
