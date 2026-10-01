import { Badge, Card, CardHeader } from '@/components/ui'
import { can, type Access } from '@/lib/access'
import { StageSelect } from '../StageMove'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']

// The contract's stage: any stage can be chosen (the database keeps the one money lock and the history).
export async function PipelineCard({ supabase, access, proposalId }: { supabase: Supa; access: Access | null; proposalId: string }) {
  const { data: c } = await supabase.from('operational_cases')
    .select('id,canonical_state,current_stage_id,entered_stage_at,due_at,pendency_reason,pendency_due_at')
    .eq('proposal_id', proposalId).maybeSingle()
  if (!c) return null
  // The stage history is in the contract history card.
  const { data: stages } = await supabase.from('operational_stages').select('id,name,canonical_state').eq('is_active', true).order('sort_order')
  const stage = (stages ?? []).find(s => s.id === c.current_stage_id)

  return (
    <Card className="mt-4">
      <CardHeader title={<span className="flex items-center gap-2">Esteira <Badge tone="paid-out">{stage?.name ?? c.canonical_state}</Badge></span>} />
      <div className="space-y-4 p-5 pt-3 text-sm">
        <p className="text-muted">Nesta etapa desde {new Date(c.entered_stage_at).toLocaleString('pt-BR')}{c.due_at ? ` · prazo ${new Date(c.due_at).toLocaleString('pt-BR')}` : ''}</p>
        {c.pendency_reason && (
          <p className="rounded-lg bg-[#FEF3C7] px-3 py-2 text-[#92400E]"><strong>Pendência:</strong> {c.pendency_reason}{c.pendency_due_at ? ` · resolver até ${new Date(c.pendency_due_at).toLocaleDateString('pt-BR')}` : ''}</p>
        )}
        {can(access, 'esteira.edit') && (
          <div className="max-w-md">
            <p className="mb-1.5 text-[13px] font-medium text-ink-soft">Mover para</p>
            <StageSelect caseId={c.id} proposalId={proposalId} stages={stages ?? []} currentStageId={c.current_stage_id} label="Mover para" />
          </div>
        )}
      </div>
    </Card>
  )
}
