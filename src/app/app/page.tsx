import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'

export default async function DashboardPage() {
  const { supabase, organization, membership } = await requireAppContext()
  const canSeeFinance = ['admin','manager','supervisor'].includes(membership.role)
  const [customers, proposals, jobs, cases, divergences, reviews, expected, received, reversals] = await Promise.all([
    supabase.from('clients').select('*', { count: 'exact', head: true }).is('deleted_at', null),
    supabase.from('proposals_v2').select('*', { count: 'exact', head: true }),
    supabase.from('digitization_jobs').select('*', { count: 'exact', head: true }).in('status', ['queued','assigned','in_progress','blocked']),
    supabase.from('operational_cases').select('*', { count: 'exact', head: true }).not('canonical_state','in','("paid","cancelled","rejected")'),
    supabase.from('financial_reconciliation_cases').select('*',{count:'exact',head:true}).in('status',['divergent','human_required']),
    supabase.from('import_match_candidates').select('*',{count:'exact',head:true}).eq('status','human_required'),
    supabase.from('financial_events').select('amount').eq('event_type','commission_expected'),
    supabase.from('financial_events').select('amount').eq('event_type','payment_received'),
    supabase.from('financial_events').select('amount,metadata').eq('event_type','reversal'),
  ])
  const cards = [
    ['Clientes ativos', customers.count ?? 0, '/app/clientes'],
    ['Propostas', proposals.count ?? 0, '/app/propostas'],
    ['Fila de digitação', jobs.count ?? 0, '/app/operacao'],
    ['Casos em andamento', cases.count ?? 0, '/app/operacao'],
  ] as const
  const expectedTotal=(expected.data??[]).reduce((s,x)=>s+Number(x.amount),0)
  // Reversals are compensating events: they net against the bucket of the event they reverse.
  const reversedOf=(type:string)=>(reversals.data??[]).filter(r=>(r.metadata as {reversed_event_type?:string}|null)?.reversed_event_type===type).reduce((s,x)=>s+Number(x.amount),0)
  const expectedNet=expectedTotal-reversedOf('commission_expected')
  const receivedTotal=(received.data??[]).reduce((s,x)=>s+Number(x.amount),0)-reversedOf('payment_received')
  return <section>
    <div className="mb-8"><p className="text-sm text-emerald-400">Vertical Slice V0</p><h1 className="mt-1 text-3xl font-semibold">Visão geral</h1><p className="mt-2 text-slate-400">{organization?.name}</p></div>
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">{cards.map(([label,value,href]) => <Link href={href} key={label} className="rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-slate-700"><div className="text-sm text-slate-400">{label}</div><div className="mt-3 text-3xl font-semibold">{value}</div></Link>)}</div>
    <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {canSeeFinance&&<><Link href="/app/financeiro" className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">Comissão esperada</div><div className="mt-3 text-2xl font-semibold">R$ {expectedNet.toLocaleString('pt-BR',{minimumFractionDigits:2})}</div></Link>
      <Link href="/app/financeiro" className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">Recebido comprovado</div><div className="mt-3 text-2xl font-semibold">R$ {receivedTotal.toLocaleString('pt-BR',{minimumFractionDigits:2})}</div></Link>
      <Link href="/app/financeiro" className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">Divergências financeiras</div><div className="mt-3 text-3xl font-semibold">{divergences.count ?? 0}</div></Link></>}
      <Link href="/app/importacoes" className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">Revisões humanas</div><div className="mt-3 text-3xl font-semibold">{reviews.count ?? 0}</div></Link>
    </div>
    <div className="mt-8 rounded-2xl border border-slate-800 bg-slate-900 p-6"><h2 className="font-semibold">Fluxo operacional</h2><p className="mt-2 text-sm leading-6 text-slate-400">Cliente → Simulação → Proposta → Documentos → Digitação → Pipeline. Os dados desta tela são consultados diretamente no tenant autenticado e protegidos por RLS.</p></div>
  </section>
}
