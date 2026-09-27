import Link from 'next/link'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { transitionOperationalCase } from './actions'
import { atLeast } from '@/lib/rbac'
import { OPERATIONAL_MESSAGES, caseStateLabel, isOperationalErrorCode, jobStatusLabel } from '@/lib/operational'

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
    <PageHeader title="Operação" description="Fila de digitação e esteira técnica separadas da apresentação comercial." />
    {isOperationalErrorCode(sp.erro) && <p role="alert" className="mb-4 rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-3 text-sm text-[#92400E]">{OPERATIONAL_MESSAGES[sp.erro]}</p>}
    {sp.ok && <p role="status" className="mb-4 rounded-[10px] border border-[#BBE5C8] bg-[#E3F5E9] px-4 py-3 text-sm text-[#15803D]">Transição registrada.</p>}
    {(casesResult.error || jobsResult.error) && <p role="alert" className="mb-4 rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">Não foi possível carregar toda a esteira agora. Os dados abaixo podem estar incompletos.</p>}

    <div className="grid gap-6 xl:grid-cols-2">
      <div>
        <div className="mb-3 flex items-center justify-between"><h2 className="font-semibold text-ink">Fila de digitação</h2><span className="text-xs text-muted">{jobsResult.data?.length ?? 0} ativo(s)</span></div>
        <div className="grid gap-3">
          {jobsResult.data?.map(j => <Card key={j.id} className="p-5">
            <div className="flex items-center justify-between gap-3">
              <div><div className="text-xs text-muted"><Link href={`/app/propostas/${j.proposal_id}`} className="hover:text-brand">Proposta {j.proposal_id.slice(0, 8)}</Link></div><div className="mt-1 font-medium text-ink">{jobStatusLabel(j.status)}</div></div>
              <div className="text-right text-xs text-muted"><div>Prioridade {j.priority}</div><div>Tentativas {j.attempt_count}</div></div>
            </div>
            {j.last_error && <p className="mt-3 rounded-[10px] bg-[#FDE2E1] p-2 text-xs text-[#991B1B]">{j.last_error}</p>}
          </Card>)}
          {!jobsResult.data?.length && <Card className="p-8 text-center text-sm text-muted">Fila vazia.</Card>}
        </div>
      </div>

      <div>
        <div className="mb-3 flex items-center justify-between"><h2 className="font-semibold text-ink">Casos operacionais</h2><span className="text-xs text-muted">{casesResult.data?.length ?? 0} caso(s)</span></div>
        <div className="grid gap-3">
          {casesResult.data?.map(c => <Card key={c.id} className="p-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div><div className="text-xs text-muted"><Link href={`/app/propostas/${c.proposal_id}`} className="hover:text-brand">Proposta {c.proposal_id.slice(0, 8)}</Link></div><div className="mt-1 font-medium text-ink">{caseStateLabel(c.canonical_state).label}</div><div className="mt-1 text-xs text-ink-soft">{caseStateLabel(c.canonical_state).next}</div></div>
              <div className="text-sm text-ink-soft">{c.external_status_raw ?? 'Sem status externo'}</div>
            </div>
            {c.due_at && <div className="mt-3 text-xs text-muted">SLA: {new Date(c.due_at).toLocaleString('pt-BR')}</div>}
            {!['approved','paid','rejected','cancelled'].includes(c.canonical_state) && <form action={transitionOperationalCase} className="mt-4 flex flex-wrap gap-2">
              <input type="hidden" name="case_id" value={c.id}/>
              {c.canonical_state === 'digitization_queue' && <button name="to_state" value="digitizing" className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Iniciar digitação</button>}
              {c.canonical_state === 'digitizing' && <button name="to_state" value="submitted" className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Marcar enviado</button>}
              {c.canonical_state === 'submitted' && <button name="to_state" value="pending_external" className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-muted">Aguardando banco</button>}
              {['submitted','pending_external'].includes(c.canonical_state) && atLeast(membership.role,'supervisor') && <>
                <button name="to_state" value="approved" className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Aprovado</button>
                <button name="to_state" value="rejected" className="inline-flex h-9 items-center rounded-[10px] bg-[#FDE2E1] px-3 text-xs font-semibold text-[#991B1B]">Rejeitado</button>
              </>}
              {atLeast(membership.role,'supervisor') && <button name="to_state" value="cancelled" className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 text-xs text-ink-soft hover:bg-surface-muted">Cancelar</button>}
            </form>}
          </Card>)}
          {!casesResult.data?.length && <Card className="p-8 text-center text-sm text-muted">Nenhum caso operacional.</Card>}
        </div>
      </div>
    </div>
  </section>
}
