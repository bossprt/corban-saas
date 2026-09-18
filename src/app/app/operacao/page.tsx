import { requireAppContext } from '@/lib/appContext'
export default async function OperationsPage() {
  const { supabase } = await requireAppContext()
  const { data: cases } = await supabase.from('operational_cases').select('id,canonical_state,external_status_raw,entered_stage_at,due_at,proposal_id').order('updated_at',{ascending:false}).limit(100)
  return <section><h1 className="text-3xl font-semibold">Operação</h1><p className="mt-2 text-sm text-slate-400">Esteira técnica separada da apresentação visual.</p>
    <div className="mt-6 grid gap-3">{cases?.map(c=><div key={c.id} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="flex flex-wrap items-center justify-between gap-3"><div><div className="text-xs text-slate-500">Proposta {c.proposal_id.slice(0,8)}</div><div className="mt-1 font-medium">{c.canonical_state}</div></div><div className="text-sm text-slate-400">{c.external_status_raw??'Sem status externo'}</div></div></div>)}{!cases?.length&&<div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 text-center text-slate-500">Nenhum caso operacional.</div>}</div>
  </section>
}
