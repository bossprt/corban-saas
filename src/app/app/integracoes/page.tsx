import { requireAppContext } from '@/lib/appContext'
import { PHASE_LABEL, classifyRunsView, runPhase, type RunRow } from '@/lib/integrations/view-state'
import { PROVIDER_REGISTRY, usability } from '@/lib/integrations/registry'

const BASE='id,status,capability,attempt_count,max_attempts,error_code,created_at,finished_at'
const FULL=`${BASE},terminal,next_attempt_at,correlation_id`

export default async function IntegrationsPage() {
  const { supabase, membership } = await requireAppContext()
  // Runs (and their raw provider payloads) are supervisor+ by RLS. Before 20260921_integration_run_state_machine_v1 the extra columns
  // do not exist: fall back to the base columns instead of showing a broken page.
  type Res = { data: unknown; error: { code?: string } | null }
  let res: Res = await supabase.from('integration_runs').select(FULL).order('created_at', { ascending: false }).limit(100)
  if (res.error && String(res.error.code) === '42703') res = await supabase.from('integration_runs').select(BASE).order('created_at', { ascending: false }).limit(100)
  const view = classifyRunsView({ role: membership.role, error: res.error, rows: (res.data ?? null) as RunRow[] | null })

  return <section>
    <h1 className="text-3xl font-semibold">Integrações</h1>
    <p className="mt-2 text-sm text-slate-400">Execuções de provedores. Um retorno de sucesso do provedor é evidência da execução, nunca receita nem status de pagamento.</p>

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
    {view.kind === 'ready' && <div className="mt-3 space-y-2">{view.rows.map(r => {
      const phase = runPhase({ status: r.status, terminal: r.terminal, attempt_count: r.attempt_count, max_attempts: r.max_attempts })
      return <div key={r.id} className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm">
        <div className="flex flex-wrap items-baseline justify-between gap-2"><strong>{r.capability}</strong><span className={phase === 'completed' ? 'text-emerald-400' : phase === 'needs_human' ? 'text-red-300' : 'text-slate-300'}>{PHASE_LABEL[phase]}</span></div>
        <div className="mt-1 text-xs text-slate-400">Tentativa {r.attempt_count}/{r.max_attempts}{r.error_code ? ` · ${r.error_code}` : ''}{r.next_attempt_at ? ` · próxima em ${new Date(r.next_attempt_at).toLocaleString('pt-BR')}` : ''}</div>
        {r.correlation_id && <div className="mt-1 text-xs text-slate-500">correlação {r.correlation_id}</div>}
      </div>
    })}</div>}
  </section>
}
