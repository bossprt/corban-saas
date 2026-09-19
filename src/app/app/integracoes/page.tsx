import { requireAppContext } from '@/lib/appContext'
import { PHASE_LABEL, RUN_ERROR_MESSAGES, RUN_OK_MESSAGES, allowedActions, classifyRunsView, isRunFeedback, isRunOk, lineageOf, runPhase, type RunRow } from '@/lib/integrations/view-state'
import { cancelRun, reexecuteRun, retryRun } from './actions'
import { PROVIDER_REGISTRY, usability } from '@/lib/integrations/registry'

const BASE='id,status,capability,attempt_count,max_attempts,error_code,created_at,finished_at'
const FULL=`${BASE},terminal,next_attempt_at,correlation_id`
const RICH=`${FULL},updated_at,parent_run_id,reexecution_reason,adapter:integration_adapters(adapter_key)`

export default async function IntegrationsPage({ searchParams }: { searchParams: Promise<{ erro?: string; ok?: string }> }) {
  const { supabase, membership } = await requireAppContext()
  const sp = await searchParams
  // Runs (and their raw provider payloads) are supervisor+ by RLS. Older schemas lack the newer columns: degrade instead of breaking.
  type Res = { data: unknown; error: { code?: string } | null }
  let res: Res = await supabase.from('integration_runs').select(RICH).order('created_at', { ascending: false }).limit(100)
  if (res.error) res = await supabase.from('integration_runs').select(FULL).order('created_at', { ascending: false }).limit(100)
  if (res.error && String(res.error.code) === '42703') res = await supabase.from('integration_runs').select(BASE).order('created_at', { ascending: false }).limit(100)
  const view = classifyRunsView({ role: membership.role, error: res.error, rows: (res.data ?? null) as RunRow[] | null })

  return <section>
    <h1 className="text-3xl font-semibold">Integrações</h1>
    <p className="mt-2 text-sm text-slate-400">Execuções de provedores. Um retorno de sucesso do provedor é evidência da execução, nunca receita nem status de pagamento.</p>

    {isRunFeedback(sp.erro) && <p role="alert" className="mt-4 rounded-xl border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-200">{RUN_ERROR_MESSAGES[sp.erro]}</p>}
    {isRunOk(sp.ok) && <p role="status" className="mt-4 rounded-xl border border-emerald-500/40 bg-emerald-500/10 p-3 text-sm text-emerald-200">{RUN_OK_MESSAGES[sp.ok]}</p>}

    <div className="mt-6 grid gap-3 md:grid-cols-2">
      {PROVIDER_REGISTRY.map(e => {
        const u = usability(e.manifest.adapterKey)
        return <div key={e.manifest.adapterKey} className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm">
          <div className="flex items-baseline justify-between gap-2"><strong>{e.manifest.adapterKey}</strong><span className={u.usable ? 'text-emerald-400' : 'text-amber-300'}>{u.usable ? 'Disponível (local)' : 'Bloqueado'}</span></div>
          <div className="mt-1 text-xs text-slate-400">{e.manifest.transport === 'file' ? 'Arquivo' : 'API'} · {Object.keys(e.manifest.capabilities).length} capacidade(s)</div>
          {!u.usable && <p className="mt-2 text-xs text-amber-200">{e.blockedReason ?? u.reason}</p>}
        </div>
      })}
    </div>

    <h2 className="mt-8 text-xl font-semibold">Execuções</h2>
    {view.kind === 'permission_denied' && <p role="alert" className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-300">Seu perfil não tem permissão para ver execuções de integração.</p>}
    {view.kind === 'unavailable' && <p className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">O registro de execuções ainda não está disponível neste ambiente (migration pendente de autorização).</p>}
    {view.kind === 'error' && <p role="alert" className="mt-3 text-amber-300">Não foi possível consultar as execuções agora. Tente novamente.</p>}
    {view.kind === 'empty' && <p className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">Nenhuma execução registrada.</p>}
    {view.kind === 'ready' && <div className="mt-3 space-y-2">{(() => { const childOf = lineageOf(view.rows); return view.rows.map(r => {
      const phase = runPhase({ status: r.status, terminal: r.terminal, attempt_count: r.attempt_count, max_attempts: r.max_attempts })
      const act = allowedActions(membership.role, { status: r.status, terminal: r.terminal, attempt_count: r.attempt_count, max_attempts: r.max_attempts })
      const adapter = Array.isArray(r.adapter) ? r.adapter[0] : r.adapter
      return <div key={r.id} className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm">
        <div className="flex flex-wrap items-baseline justify-between gap-2"><strong>{adapter?.adapter_key ?? 'provedor'} · {r.capability}</strong><span className={phase === 'completed' ? 'text-emerald-400' : phase === 'needs_human' ? 'text-red-300' : 'text-slate-300'}>{PHASE_LABEL[phase]}</span></div>
        <div className="mt-1 text-xs text-slate-400">Tentativa {r.attempt_count}/{r.max_attempts}{r.error_code ? ` · ${r.error_code}` : ''}{r.next_attempt_at ? ` · próxima em ${new Date(r.next_attempt_at).toLocaleString('pt-BR')}` : ''}{r.updated_at ? ` · atualizado ${new Date(r.updated_at).toLocaleString('pt-BR')}` : ''}</div>
        <div className="mt-1 text-xs text-slate-500">{r.correlation_id ? `correlação ${r.correlation_id}` : ''}{r.parent_run_id ? ` · nova execução de ${r.parent_run_id.slice(0, 8)}` : ''}{childOf.has(r.id) ? ` · execução original; refeita como ${String(childOf.get(r.id)).slice(0, 8)}` : ''}</div>
        {r.reexecution_reason && <div className="mt-1 text-xs text-slate-400">Motivo da nova execução: {r.reexecution_reason}</div>}
        {(act.retry || act.cancel || act.reexecute) && <div className="mt-3 flex flex-wrap items-center gap-2">
          {act.retry && <form action={retryRun}><input type="hidden" name="run_id" value={r.id} /><button className="rounded border border-slate-700 px-2 py-1 text-xs" title="Continua a mesma execução; respeita espera e limite de tentativas">Nova tentativa</button></form>}
          {act.cancel && <form action={cancelRun}><input type="hidden" name="run_id" value={r.id} /><button className="rounded border border-slate-700 px-2 py-1 text-xs">Cancelar</button></form>}
          {act.reexecute && <form action={reexecuteRun} className="flex gap-1"><input type="hidden" name="run_id" value={r.id} /><input name="reason" required minLength={10} maxLength={500} placeholder="Motivo da nova execução" className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs" /><button className="rounded bg-emerald-500 px-2 py-1 text-xs font-semibold text-slate-950" title="Cria uma execução NOVA ligada a esta; o histórico desta não muda">Nova execução</button></form>}
        </div>}
      </div>
    }) })()}</div>}
  </section>
}
