// Several à vista receipts at once (06/11/2026). No I/O: builds the items for public.register_manual_receipts_bulk and
// turns its refusal into one short sentence. Money stays decimal text; totals are integer cents.
import { parseMoneyInput } from '../money-input'

export type BulkItem = { proposal_id: string; amount: string }
export const BULK_MAX = 100
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// ids: the contracts ticked; amountOf: the amount typed on each line. Refuses an empty pick, too many, or a bad amount.
export function buildBulkItems(ids: string[], amountOf: (id: string) => unknown): { ok: true; items: BulkItem[] } | { ok: false; error: string } {
  const unique = [...new Set(ids.filter(id => UUID.test(id)))]
  if (!unique.length) return { ok: false, error: 'Marque pelo menos um contrato.' }
  if (unique.length > BULK_MAX) return { ok: false, error: `Marque no máximo ${BULK_MAX} contratos por vez.` }
  const items: BulkItem[] = []
  for (const id of unique) {
    const amount = parseMoneyInput(amountOf(id))
    if (amount === null || amount === 'invalid' || amount === '0.00') return { ok: false, error: 'Confira os valores: cada contrato marcado precisa de um valor maior que zero, no formato 1.234,56.' }
    items.push({ proposal_id: id, amount })
  }
  return { ok: true, items }
}

// Sum in cents of decimal texts ("600.00").
export function totalCents(amounts: string[]): number {
  return amounts.reduce((s, a) => {
    const m = /^(\d+)\.(\d{2})$/.exec(a)
    return m ? s + Number(m[1]) * 100 + Number(m[2]) : s
  }, 0)
}

// The database names the contract that failed: "bulk_receipt_item:<ADE>:<reason>". Nothing was recorded.
export function bulkReceiptError(message: string | null | undefined): string {
  const m = String(message ?? '')
  const item = /bulk_receipt_item:([^:]{1,60}):([\s\S]*)$/.exec(m)
  const who = item ? `Contrato ${item[1]}: ` : ''
  const reason = item ? item[2] : m
  const text = /manual_receipt_duplicate/.test(reason) ? 'o recebimento à vista já foi registrado.'
    : /manual_receipt_no_calc/.test(reason) ? 'ainda não tem comissão calculada.'
    : /invalid_receipt_amount/.test(reason) ? 'valor inválido.'
    : /invalid_receipt_date/.test(reason) ? 'data inválida (use a data em que o dinheiro caiu, até hoje).'
    : /receipt_source_not_found/.test(reason) ? 'não foi possível saber de quem vem a comissão (banco ou promotora).'
    : /not_authorized/.test(reason) ? 'seu perfil não pode registrar recebimentos.'
    : /proposal_not_found/.test(reason) ? 'contrato não encontrado.'
    : /bulk_receipt_invalid/.test(reason) ? 'lista de contratos inválida.'
    : 'não foi possível registrar.'
  const sentence = who ? `${who}${text}` : text.charAt(0).toUpperCase() + text.slice(1)
  return `${sentence} Nada foi registrado; corrija e tente de novo.`
}
