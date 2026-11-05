import { parseMoneyInput } from '../money-input'

// "Buscar" on the company entries list (owner approval 05/11/2026): a piece of the description, counterpart or document,
// or the amount ("5000", "5.000", "5.000,00"). Returns a PostgREST or() filter, or null when there is nothing to search.
// Characters that have a meaning in the filter syntax are dropped, so the typed text can never change the query.
export function entrySearchFilter(raw: unknown): string | null {
  const term = String(raw ?? '').replace(/[,()"\\*%:]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80)
  if (!term) return null
  const like = `*${term}*`
  const parts = [`description.ilike."${like}"`, `counterpart.ilike."${like}"`, `document.ilike."${like}"`]
  const money = /^(R\$\s?)?[\d.]+(\s?,\s?\d{1,2})?$/.test(String(raw ?? '').trim()) ? parseMoneyInput(String(raw).trim()) : null
  if (money && money !== 'invalid') parts.push(`amount.eq.${money}`)
  return parts.join(',')
}
