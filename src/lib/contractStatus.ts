// One set of names for the situation of a contract (proposal), shared by Esteira, Contratos, the contract file, the
// filters and the reports (audit 06/11/2026: the same contract read "Aguardando digitação" in the Esteira and "Em
// digitação" in Contratos).
//
// A contract that has entered the Esteira takes the state of its pipeline case (the stage the operation sees). Before
// the queue it has only the proposal status. proposals_v2.status is coarser than the case ("digitization" covers both
// "Aguardando" and "Em digitação"; "submitted" covers "Em análise" and "Pendência"), so the case wins when it exists.

export const PRE_QUEUE_SITUATIONS = ['draft', 'documents_pending', 'ready_for_digitization'] as const
export const PIPELINE_SITUATIONS = ['digitization_queue', 'digitizing', 'submitted', 'pending_external', 'approved', 'paid', 'rejected', 'cancelled'] as const
export const SITUATIONS = [...PRE_QUEUE_SITUATIONS, ...PIPELINE_SITUATIONS] as const
export type Situation = (typeof SITUATIONS)[number]

export const SITUATION_LABEL: Record<Situation, string> = {
  draft: 'Rascunho',
  documents_pending: 'Documentos pendentes',
  ready_for_digitization: 'Pronta para a fila',
  digitization_queue: 'Aguardando digitação',
  digitizing: 'Em digitação',
  submitted: 'Em análise no banco',
  pending_external: 'Pendência',
  approved: 'Aprovada',
  paid: 'Paga',
  rejected: 'Recusada',
  cancelled: 'Cancelada',
}

export const SITUATION_NEXT: Record<Situation, string> = {
  draft: 'Prepare a lista de documentos da proposta.',
  documents_pending: 'Anexe os documentos exigidos; um supervisor valida.',
  ready_for_digitization: 'Envie para a fila de digitação.',
  digitization_queue: 'Alguém precisa iniciar a digitação.',
  digitizing: 'Quando terminar, mova para Em análise no banco.',
  submitted: 'Aguarde o retorno do banco.',
  pending_external: 'Resolva a pendência pedida pelo banco.',
  approved: 'Quando o banco pagar o cliente, mova para Paga com a data.',
  paid: 'Encerrada.',
  rejected: 'Encerrada.',
  cancelled: 'Encerrada.',
}

export const isSituation = (v: unknown): v is Situation => typeof v === 'string' && (SITUATIONS as readonly string[]).includes(v)
export const isPreQueue = (v: unknown) => typeof v === 'string' && (PRE_QUEUE_SITUATIONS as readonly string[]).includes(v)

// The situation of one contract: its pipeline case when it has one, otherwise its proposal status.
export function contractSituation(status: string | null | undefined, caseState?: string | null): Situation | null {
  if (caseState && (PIPELINE_SITUATIONS as readonly string[]).includes(caseState)) return caseState as Situation
  if (status === 'digitization') return 'digitization_queue'
  return isSituation(status) ? status : null
}

// "Paga" is said to be confirmed by evidence only when it really came from a bank file (contract import or commission
// report). Moved to Paga by hand (allowed since 01/10/2026) it is just "Paga".
export const PAID_EVIDENCE_SOURCES = ['import', 'commission_report'] as const
export const paidByEvidence = (source: string | null | undefined) => (PAID_EVIDENCE_SOURCES as readonly string[]).includes(source ?? '')

// The name shown: the company's own stage name when known (the Esteira shows it), otherwise the shared name.
export function situationLabel(s: Situation | null, opts: { stageName?: string | null; paidSource?: string | null } = {}): string {
  if (!s) return 'Situação desconhecida'
  const base = opts.stageName?.trim() || SITUATION_LABEL[s]
  return s === 'paid' && paidByEvidence(opts.paidSource) ? `${base} (confirmada por evidência)` : base
}

// Options of a "Situação" filter: every situation once, in the order of the work. A pipeline state with exactly one
// active company stage uses that stage's name, so the filter reads like the Esteira.
export function situationOptions(stages: { canonical_state: string; name: string }[] = []): { value: Situation; label: string }[] {
  return SITUATIONS.map(s => {
    const own = stages.filter(x => x.canonical_state === s)
    return { value: s, label: own.length === 1 ? own[0].name : SITUATION_LABEL[s] }
  })
}

// A filter value from the address: a known situation, or nothing (an old or mistyped value shows everything).
export const situationFilter = (v: string | null | undefined): Situation | '' => (isSituation(v) ? v : '')

export const matchesSituation = (filter: Situation | '', status: string, caseState?: string | null) => !filter || contractSituation(status, caseState) === filter
