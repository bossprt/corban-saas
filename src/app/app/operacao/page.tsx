import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { transitionOperationalCase } from './actions'
import { atLeast } from '@/lib/rbac'
import { OPERATIONAL_MESSAGES, isOperationalErrorCode } from '@/lib/operational'

export default async function OperationsPage({ searchParams }: { searchParams: Promise<{ erro?: string; ok?: string }> }) {
  const { supabase, membership } = await requireAppContext()
  const sp = await searchParams
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
    {isOperationalErrorCode(sp.erro) && <p role="alert" className="mt-4 rounded-xl border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-200">{OPERATIONAL_MESSAGES[sp.erro]}</p>}
    {sp.ok && <p role="status" className="mt-4 rounded-xl border border-emerald-500/40 bg-emerald-500/10 p-3 text-sm text-emerald-200">Transição registrada.</p>}
    {(casesResult.error || jobsResult.error) && <p role="alert" className="mt-4 rounded-xl border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-200">Não foi possível carregar toda a esteira agora. Os dados abaixo podem estar incompletos.</p>}

    <div className="mt-6 grid gap-6 xl:grid-cols-2">
      <div>
        <div className="mb-3 flex items-center justify-between"><h2 className="font-semibold">Fila de digitação</h2><span className="text-xs text-slate-500">{jobsResult.data?.length ?? 0} ativo(s)</span></div>
        <div className="grid gap-3">
          {jobsResult.data?.map(j => <div key={j.id} className="rounded-xl border border-slate-800 bg-slate-900 p-5">
            <div className="flex items-center justify-between gap-3">
              <div><div className="text-xs text-slate-500"><Link href={`/app/propostas/${j.proposal_id}`} className="hover:text-emerald-400">Proposta {j.proposal_id.slice(0, 8)}</Link></div><div className="mt-1 font-medium">{j.status}</div></div>
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
              <div><div className="text-xs text-slate-500"><Link href={`/app/propostas/${c.proposal_id}`} className="hover:text-emerald-400">Proposta {c.proposal_id.slice(0, 8)}</Link></div><div className="mt-1 font-medium">{c.canonical_state}</div></div>
              <div className="text-sm text-slate-400">{c.external_status_raw ?? 'Sem status externo'}</div>
            </div>
            {c.due_at && <div className="mt-3 text-xs text-slate-500">SLA: {new Date(c.due_at).toLocaleString('pt-BR')}</div>}
            {!['approved','paid','rejected','cancelled'].includes(c.canonical_state) && <form action={transitionOperationalCase} className="mt-4 flex flex-wrap gap-2">
              <input type="hidden" name="case_id" value={c.id}/>
              {c.canonical_state === 'digitization_queue' && <button name="to_state" value="digitizing" className="rounded-lg bg-blue-600 px-3 py-2 text-xs font-semibold text-white">Iniciar digitação</button>}
              {c.canonical_state === 'digitizing' && <button name="to_state" value="submitted" className="rounded-lg bg-blue-600 px-3 py-2 text-xs font-semibold text-white">Marcar enviado</button>}
              {c.canonical_state === 'submitted' && <button name="to_state" value="pending_external" className="rounded-lg bg-slate-700 px-3 py-2 text-xs font-semibold">Aguardando banco</button>}
              {['submitted','pending_external'].includes(c.canonical_state) && atLeast(membership.role,'supervisor') && <>
                <button name="to_state" value="approved" className="rounded-lg bg-emerald-500 px-3 py-2 text-xs font-semibold text-slate-950">Aprovado</button>
                <button name="to_state" value="rejected" className="rounded-lg bg-red-500/20 px-3 py-2 text-xs font-semibold text-red-300">Rejeitado</button>
              </>}
              {atLeast(membership.role,'supervisor') && <button name="to_state" value="cancelled" className="rounded-lg border border-slate-700 px-3 py-2 text-xs text-slate-300">Cancelar</button>}
            </form>}
          </div>)}
          {!casesResult.data?.length && <div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 text-center text-slate-500">Nenhum caso operacional.</div>}
        </div>
      </div>
    </div>
  </section>
}
