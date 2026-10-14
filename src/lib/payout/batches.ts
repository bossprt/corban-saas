// Payment batches (Repasse > Lotes de pagamento): rows from payout_batch_list / payout_batch_detail. Money comes as
// decimal text from the database, never as a float.

export type BatchRow = {
  id: string; paid_on: string; payment_reference: string | null; origin: string; created_at: string; paid_by: string | null
  payouts: number; total: string; undone: number; bank_accounts: string | null; reversed_at: string | null; reversal_reason: string | null
}

export type BatchContract = { proposal_id: string; ade: string | null; client: string | null; amount: string }
export type BatchLine = {
  payout_id: string; account_id: string; holder: string; kind: string; amount: string; status: string; reversal_reason: string | null
  contracts: BatchContract[]
}
export type BatchDetail = {
  id: string; paid_on: string; payment_reference: string | null; origin: string; created_at: string; paid_by: string | null
  reversed_at: string | null; reversal_reason: string | null; reversed_by: string | null; bank_accounts: string | null; total: string; lines: BatchLine[]
}

// A batch is undone when all its payments were undone, partly undone when some were.
export function batchStatus(b: { payouts: number; undone: number }): { label: string; tone: 'received' | 'neutral' | 'diverged' } {
  if (b.undone === 0) return { label: 'Pago', tone: 'received' }
  if (b.undone >= b.payouts) return { label: 'Desfeito', tone: 'neutral' }
  return { label: 'Desfeito em parte', tone: 'diverged' }
}
