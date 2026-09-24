import { Badge, Card, CardHeader } from '@/components/ui'
import { can, type Access } from '@/lib/access'
import { movePipeline } from './pipeline-actions'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']

// Moves offered from each state. The database is the authority (move_operational_case / transition_operational_case).
const NEXT: Record<string, string[]> = {
  digitization_queue: ['digitizing', 'cancelled'],
  digitizing: ['submitted', 'cancelled'],
  submitted: ['pending_external', 'approved', 'paid', 'rejected', 'cancelled'],
  pending_external: ['submitted', 'approved', 'paid', 'rejected', 'cancelled'],
  approved: ['paid', 'pending_external', 'cancelled'],
}
const ACTION_LABEL: Record<string, string> = {
  digitizing: 'Começar digitação', submitted: 'Digitada / em análise', pending_external: 'Abrir pendência', approved: 'Aprovada',
  paid: 'Paga', rejected: 'Recusada', cancelled: 'Cancelar',
}

// Server-rendered per request: the earliest due date a pendency can have.
const tomorrowIso = () => new Date(Date.now() + 86_400_000).toISOString().slice(0, 10)

export async function PipelineCard({ supabase, access, proposalId }: { supabase: Supa; access: Access | null; proposalId: string }) {
  const { data: c } = await supabase.from('operational_cases')
    .select('id,canonical_state,current_stage_id,entered_stage_at,due_at,pendency_reason,pendency_due_at')
    .eq('proposal_id', proposalId).maybeSingle()
  if (!c) return null
  const [{ data: stage }, { data: events }] = await Promise.all([
    supabase.from('operational_stages').select('name').eq('id', c.current_stage_id).maybeSingle(),
    supabase.from('operational_events').select('id,from_state,to_state,metadata,occurred_at').eq('operational_case_id', c.id).order('occurred_at', { ascending: false }).limit(8),
  ])
  const moves = NEXT[c.canonical_state] ?? []
  const editable = can(access, 'esteira.edit') && moves.length > 0
  const tomorrow = tomorrowIso()

  return (
    <Card className="mt-6">
      <CardHeader title={<span className="flex items-center gap-2">Esteira <Badge tone="paid-out">{stage?.name ?? c.canonical_state}</Badge></span>} />
      <div className="space-y-4 p-5 pt-3 text-sm">
        <p className="text-muted">Nesta etapa desde {new Date(c.entered_stage_at).toLocaleString('pt-BR')}{c.due_at ? ` · prazo ${new Date(c.due_at).toLocaleString('pt-BR')}` : ''}</p>
        {c.pendency_reason && (
          <p className="rounded-lg bg-[#FEF3C7] px-3 py-2 text-[#92400E]"><strong>Pendência:</strong> {c.pendency_reason}{c.pendency_due_at ? ` · resolver até ${new Date(c.pendency_due_at).toLocaleDateString('pt-BR')}` : ''}</p>
        )}
        {editable && (
          <form action={movePipeline} className="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
            <input type="hidden" name="proposal_id" value={proposalId} />
            <input type="hidden" name="case_id" value={c.id} />
            <label className="text-[13px] font-medium text-ink-soft">Mover para
              <select name="to_state" className="field mt-1.5" defaultValue={moves[0]}>
                {moves.map(m => <option key={m} value={m}>{ACTION_LABEL[m]}</option>)}
              </select>
            </label>
            <label className="text-[13px] font-medium text-ink-soft">Observação
              <input name="note" maxLength={500} placeholder="Obrigatória para Paga e Pendência" className="field mt-1.5" />
            </label>
            <label className="text-[13px] font-medium text-ink-soft">Prazo da pendência
              <input name="pendency_due" type="date" min={tomorrow} className="field mt-1.5" />
            </label>
            <div className="sm:col-span-3 flex justify-end">
              <button className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Salvar etapa</button>
            </div>
          </form>
        )}
        {(events ?? []).length > 0 && (
          <ul className="border-t border-line pt-3 text-xs text-muted">
            {(events ?? []).map(e => {
              const note = (e.metadata as Record<string, unknown> | null)?.note
              return <li key={e.id} className="py-0.5">{new Date(e.occurred_at).toLocaleString('pt-BR')} · {ACTION_LABEL[e.to_state ?? ''] ?? e.to_state}{note ? ` — ${String(note)}` : ''}</li>
            })}
          </ul>
        )}
      </div>
    </Card>
  )
}
