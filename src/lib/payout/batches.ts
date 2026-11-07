import type { PayTarget } from '@/lib/sellers'
// Payment batches (Repasse > Lotes de pagamento): rows from payout_batch_list / payout_batch_detail. Money comes as
// decimal text from the database, never as a float.

export type BatchRow = {
  id: string; paid_on: string; payment_reference: string | null; origin: string; created_at: string; paid_by: string | null
  // total: effective (paid) payments only; undone_total: the undone ones, apart (06/11/2026).
  payouts: number; total: string; undone: number; undone_total?: string; bank_accounts: string | null; reversed_at: string | null; reversal_reason: string | null
}

// partial: this payment paid only part of the contract (payment from the balance, oldest contracts first, 17/10/2026).
// kind: set when the item has no contract (bonus, discount, ...; 'unmatched' when the ledger could not explain it).
export type BatchContract = { proposal_id: string | null; ade: string | null; client: string | null; amount: string; partial?: boolean; kind?: string | null
  // Contract details (17/10/2026): bank, agreement, product (contract type), released to the client, paid to the client on.
  bank?: string | null; agreement?: string | null; product?: string | null; released?: string | null; paid_to_client_on?: string | null
}

const ITEM_LABEL: Record<string, string> = { bonus: 'Bônus', advance: 'Vale', discount: 'Desconto', adjustment: 'Ajuste sem contrato', commission: 'Comissão sem contrato', chargeback: 'Estorno sem contrato', unmatched: 'Sem contrato identificado',
  carry_in: 'Saldo anterior', debt_deduction: 'Desconto do negativo', carry_forward: 'Negativo que passa para o próximo período' }
export const batchItemLabel = (c: BatchContract) => c.proposal_id ? (c.ade ?? 'sem ADE') : (ITEM_LABEL[c.kind ?? ''] ?? 'Outro lançamento')

// Composition of a payment (payout_breakdown, 06/11/2026): contracts + other items (vale, bônus, desconto, ajuste sem
// contrato, saldo anterior, desconto do negativo) = total. Every amount is decimal text, signed. difference = total minus
// both sums, computed by the database and shown when it is not zero (never hidden).
export type BreakdownItem = { kind: string; description: string | null; effective_on: string | null; amount: string; partial?: boolean }
export type Breakdown = {
  contracts: BatchContract[]; contracts_total: string; others: BreakdownItem[]; others_total: string; difference: string; undone: boolean
  total?: string
}
export const breakdownItemLabel = (o: BreakdownItem) => ITEM_LABEL[o.kind] ?? 'Outro lançamento'
export type BatchLine = Breakdown & {
  payout_id: string; account_id: string; holder: string; kind: string; amount: string; status: string; reversal_reason: string | null
  // Who receives (21/10/2026): CPF/CNPJ and the primary PIX or bank account of the seller.
  holder_document?: string | null; pay_target?: PayTarget | null
}
export type Company = { name: string; document: string | null }
export type BatchDetail = {
  id: string; paid_on: string; payment_reference: string | null; origin: string; created_at: string; paid_by: string | null
  reversed_at: string | null; reversal_reason: string | null; reversed_by: string | null; bank_accounts: string | null; total: string; undone_total?: string; lines: BatchLine[]
  company?: Company
}
// One person over a period (payout_account_report).
export type AccountReport = {
  company: Company
  holder: { name: string; document: string | null; pay_target: PayTarget | null }
  from: string; to: string; total: string
  payments: (Breakdown & { payout_id: string; paid_on: string; kind: string; amount: string; reference: string | null })[]
}

// A batch is undone when all its payments were undone, partly undone when some were.
export function batchStatus(b: { payouts: number; undone: number }): { label: string; tone: 'received' | 'neutral' | 'diverged' } {
  if (b.undone === 0) return { label: 'Pago', tone: 'received' }
  if (b.undone >= b.payouts) return { label: 'Desfeito', tone: 'neutral' }
  return { label: 'Desfeito em parte', tone: 'diverged' }
}
