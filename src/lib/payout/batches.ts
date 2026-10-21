import type { PayTarget } from '@/lib/sellers'
// Payment batches (Repasse > Lotes de pagamento): rows from payout_batch_list / payout_batch_detail. Money comes as
// decimal text from the database, never as a float.

export type BatchRow = {
  id: string; paid_on: string; payment_reference: string | null; origin: string; created_at: string; paid_by: string | null
  payouts: number; total: string; undone: number; bank_accounts: string | null; reversed_at: string | null; reversal_reason: string | null
}

// partial: this payment paid only part of the contract (payment from the balance, oldest contracts first, 17/10/2026).
// kind: set when the item has no contract (bonus, discount, ...; 'unmatched' when the ledger could not explain it).
export type BatchContract = { proposal_id: string | null; ade: string | null; client: string | null; amount: string; partial?: boolean; kind?: string | null
  // Contract details (17/10/2026): bank, agreement, product (contract type), released to the client, paid to the client on.
  bank?: string | null; agreement?: string | null; product?: string | null; released?: string | null; paid_to_client_on?: string | null
}

const ITEM_LABEL: Record<string, string> = { bonus: 'Bônus', advance: 'Adiantamento', discount: 'Desconto', adjustment: 'Ajuste', commission: 'Comissão', chargeback: 'Estorno', unmatched: 'Sem contrato identificado' }
export const batchItemLabel = (c: BatchContract) => c.proposal_id ? (c.ade ?? 'sem ADE') : (ITEM_LABEL[c.kind ?? ''] ?? 'Outro lançamento')
export type BatchLine = {
  payout_id: string; account_id: string; holder: string; kind: string; amount: string; status: string; reversal_reason: string | null
  contracts: BatchContract[]
  // Who receives (21/10/2026): CPF/CNPJ and the primary PIX or bank account of the seller.
  holder_document?: string | null; pay_target?: PayTarget | null
}
export type Company = { name: string; document: string | null }
export type BatchDetail = {
  id: string; paid_on: string; payment_reference: string | null; origin: string; created_at: string; paid_by: string | null
  reversed_at: string | null; reversal_reason: string | null; reversed_by: string | null; bank_accounts: string | null; total: string; lines: BatchLine[]
  company?: Company
}
// One person over a period (payout_account_report).
export type AccountReport = {
  company: Company
  holder: { name: string; document: string | null; pay_target: PayTarget | null }
  from: string; to: string; total: string
  payments: { payout_id: string; paid_on: string; kind: string; amount: string; reference: string | null; contracts: BatchContract[] }[]
}

// A batch is undone when all its payments were undone, partly undone when some were.
export function batchStatus(b: { payouts: number; undone: number }): { label: string; tone: 'received' | 'neutral' | 'diverged' } {
  if (b.undone === 0) return { label: 'Pago', tone: 'received' }
  if (b.undone >= b.payouts) return { label: 'Desfeito', tone: 'neutral' }
  return { label: 'Desfeito em parte', tone: 'diverged' }
}
