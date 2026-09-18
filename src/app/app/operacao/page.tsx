import { requireAppContext } from '@/lib/appContext'

export default async function OperationsPage() {
  const { supabase } = await requireAppContext()
  const [casesResult, jobsResult] = await Promise.all([
    supabase.from('operational_cases')
      .select('id,canonical_state,external_status_raw,entered_stage_at,due_at,proposal_id')
      .order('updated_at', { ascending: false }).limit(100),
    supabase.from('digitization_jobs')
      .select('id,proposal_id,status,priority,assigned_to,attempt_count,queued_at,started_at,submitted_at,last_error')
      .in('status', ['queued','assigned','in_progress','blocked','submitted'])
      .order('priority', { ascending: false }).order('queued_at').limit(100),
  ])

  return <section>
    <h1 className="text-3xl font-semibold">Operação</h1>
    <p className="mt-2 text-sm text-slate-400">Fila de digitação e esteira técnica separadas da apresentação comercial.</p>

    <div className="mt-6 grid gap-6 xl:grid-cols-2">
      <div>
        <div className="mb-3 flex items-center justify-between"><h2 className="font-semibold">Fila de digitação</h2><span className="text-xs text-slate-500">{jobsResult.data?.length ?? 0} ativo(s)</span></div>
        <div className="grid gap-3">
          {jobsResult.data?.map(j => <div key={j.id} className="rounded-xl border border-slate-800 bg-slate-900 p-5">
            <div className="flex items-center justify-between gap-3">
              <div><div className="text-xs text-slate-500">Proposta {j.proposal_id.slice(0, 8)}</div><div className="mt-1 font-medium">{j.status}</div></div>
              <div className="text-right text-xs text-slate-500"><div>Prioridade {j.priority}</div><div>Tentativas {j.attempt_count}</div></div>
            </div>
            {j.last_error && <p className="mt-3 rounded-lg bg-red-500/10 p-2 text-xs text-red-300">{j.last_error}</p>}
          </div>)}
          {!jobsResult.data?.length && <div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 text-center text-slate-500">Fila vazia.</div>}
        </div>
      </div>

      <div>
        <div className="mb-3 flex items-center justify-between"><h2 className="font-semibold">Casos operacionais</h2><span className="text-xs text-slate-500">{casesResult.data?.length ?? 0} caso(s)</span></div>
        <div className="grid gap-3">
          {casesResult.data?.map(c => <div key={c.id} className="rounded-xl border border-slate-800 bg-slate-900 p-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div><div className="text-xs text-slate-500">Proposta {c.proposal_id.slice(0, 8)}</div><div className="mt-1 font-medium">{c.canonical_state}</div></div>
              <div className="text-sm text-slate-400">{c.external_status_raw ?? 'Sem status externo'}</div>
            </div>
            {c.due_at && <div className="mt-3 text-xs text-slate-500">SLA: {new Date(c.due_at).toLocaleString('pt-BR')}</div>}
          </div>)}
          {!casesResult.data?.length && <div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 text-center text-slate-500">Nenhum caso operacional.</div>}
        </div>
      </div>
    </div>
  </section>
}
