import type { ImportMapper, MappingRequest, ValidatedMapping } from './types'
import { reuseDecision, validateProposal, type ReuseDecision, type SavedMapping } from './validate'

// Port to the metering RPCs (reserve_ai_job / settle_ai_job) and to the mapping memory. The database enforces the same rules; this port lets the orchestrator and its
// tests run without any provider or database, and it is the ONLY way the mapper can be reached: no reservation, no call.
export interface MeteringPort {
  reserve(input: { capability: 'import_mapping'; provider: string; model: string; estimatedCredits: string; estimatedCost: string | null; sourceRef: string; idempotencyKey: string }): Promise<{ ok: true; jobId: string } | { ok: false; reason: 'ai_disabled' | 'insufficient_credits' | 'monthly_limit_exceeded' | 'idempotency_conflict' | 'unavailable' }>
  settle(input: { jobId: string; outcome: 'succeeded' | 'failed'; creditsCharged: string | null; actualCost: string | null; inputUnits: number | null; outputUnits: number | null }): Promise<void>
}
export interface MappingMemoryPort { find(sourceLabel: string, fingerprint: string): Promise<SavedMapping | null> }

// Credit estimate from a rate card that the PLATFORM configures (units per credit, minimum). Nothing here is a price: with no rate card the AI path is closed.
export type RateCard = { inputUnitsPerCredit: number; outputUnitsPerCredit: number; minimumCredits: number }
export function estimateCredits(card: RateCard | null, req: MappingRequest): string | null {
  if (!card || !(card.inputUnitsPerCredit > 0) || !(card.outputUnitsPerCredit > 0) || !(card.minimumCredits > 0)) return null
  const chars = req.headers.join(' ').length + req.sample.reduce((n, r) => n + r.join(' ').length, 0)
  const inputUnits = Math.ceil(chars / 4) + 200 // rough token estimate + fixed prompt overhead
  // integer arithmetic in 1/10000 credit, formatted with 4 fixed decimals (no scientific notation, no binary-float drift in the stored value)
  const scaled = Math.ceil((inputUnits * 10000) / card.inputUnitsPerCredit + (300 * 10000) / card.outputUnitsPerCredit)
  const v = Math.max(Math.round(card.minimumCredits * 10000), scaled)
  return `${Math.floor(v / 10000)}.${String(v % 10000).padStart(4, '0')}`
}

export type MappingOutcome =
  | { kind: 'reused'; mapping: ValidatedMapping['mapping'] }
  | { kind: 'proposed'; validated: ValidatedMapping; jobId: string; provider: string; model: string }
  | { kind: 'manual'; reason: 'no_mapper' | 'no_rate_card' | 'ai_disabled' | 'insufficient_credits' | 'monthly_limit_exceeded' | 'idempotency_conflict' | 'metering_unavailable' | 'mapper_failed'; review?: ReuseDecision }

// One import file -> a mapping to REVIEW. Order matters: memory first (free), then reservation, then the provider, then settlement. Every failure ends in the manual
// mapping screen: the AI is an accelerator, never a dependency, and it can never import anything by itself.
export async function proposeMapping(args: {
  request: MappingRequest; mapper: ImportMapper | null; memory: MappingMemoryPort; metering: MeteringPort; rateCard: RateCard | null; idempotencyKey: string
}): Promise<MappingOutcome> {
  const { request, mapper, memory, metering, rateCard, idempotencyKey } = args
  const saved = await memory.find(request.sourceLabel, request.fingerprint)
  const decision = reuseDecision(saved, request)
  if (decision.kind === 'reuse') return { kind: 'reused', mapping: decision.mapping }
  if (!mapper) return { kind: 'manual', reason: 'no_mapper', review: decision }
  const estimate = estimateCredits(rateCard, request)
  if (!estimate) return { kind: 'manual', reason: 'no_rate_card', review: decision }
  const reservation = await metering.reserve({ capability: 'import_mapping', provider: mapper.id, model: mapper.model, estimatedCredits: estimate, estimatedCost: null, sourceRef: request.fingerprint, idempotencyKey })
  if (!reservation.ok) return { kind: 'manual', reason: reservation.reason === 'unavailable' ? 'metering_unavailable' : reservation.reason, review: decision }
  try {
    const proposal = await mapper.mapColumns(request)
    await metering.settle({ jobId: reservation.jobId, outcome: 'succeeded', creditsCharged: estimate, actualCost: null, inputUnits: proposal.usage.inputUnits, outputUnits: proposal.usage.outputUnits })
    return { kind: 'proposed', validated: validateProposal(request, proposal), jobId: reservation.jobId, provider: proposal.provider, model: proposal.model }
  } catch {
    // a failed call releases the whole reservation (nothing is charged for a failure) and the person maps by hand
    await metering.settle({ jobId: reservation.jobId, outcome: 'failed', creditsCharged: null, actualCost: null, inputUnits: null, outputUnits: null }).catch(() => undefined)
    return { kind: 'manual', reason: 'mapper_failed', review: decision }
  }
}
