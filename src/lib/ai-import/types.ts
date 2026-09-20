// Provider-agnostic contract of the AI Import Mapper (NEXT-WAVE-PLAN-V3, wave C). The AI only proposes WHICH COLUMN MEANS WHAT; it never reads a
// value into the database, never computes money, never publishes. Parsing, validation, the human preview and the bulk import stay deterministic.

// Closed list: the same fields the database accepts in import_layout_mappings.
export const CANONICAL_FIELDS = ['bank', 'agreement', 'product_table', 'contract_type', 'term', 'coefficient', 'rate', 'received_commission', 'valid_from', 'valid_until', 'production_origin'] as const
export type CanonicalField = (typeof CANONICAL_FIELDS)[number]
// Fields where a wrong guess is a FINANCIAL error: they need a higher confidence AND deterministic evidence in the sample.
export const FINANCIAL_FIELDS: readonly CanonicalField[] = ['term', 'coefficient', 'rate', 'received_commission', 'contract_type']

export type MappingRequest = {
  sourceLabel: string
  fingerprint: string            // sha256 of the layout (ordered normalised headers)
  headers: readonly string[]
  sample: readonly (readonly string[])[]   // first rows only, already trimmed by the caller
}
export type FieldProposal = { field: CanonicalField; column: string | null; confidence: number; evidence: string }
export type MappingProposal = {
  provider: string
  model: string
  fields: FieldProposal[]
  overallConfidence: number
  usage: { inputUnits: number; outputUnits: number }
}
export interface ImportMapper {
  readonly id: string
  readonly model: string
  mapColumns(request: MappingRequest): Promise<MappingProposal>
}

// What the human sees and confirms. `unknownColumns` is ALWAYS recomputed from the headers by the validator (never trusted from the model).
export type ReviewItem = { field: CanonicalField; column: string | null; confidence: number; evidence: string; status: 'ok' | 'review' | 'missing'; reasons: string[] }
export type ValidatedMapping = {
  items: ReviewItem[]
  mapping: Partial<Record<CanonicalField, string>>   // only entries the validator accepts; still needs human confirmation
  unknownColumns: string[]
  overallConfidence: number
  needsReview: boolean       // always true unless every required field is ok; the human step is never skipped for a first import
}
