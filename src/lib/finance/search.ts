import { parseMoneyInput } from '../money-input'

// "Buscar" on the company entries list (owner approval 05/11/2026): a piece of the description, counterpart or document,
// or the amount ("5000", "5.000", "5.000,00"). Returns a PostgREST or() filter, or null when there is nothing to search.
// Characters that have a meaning in the filter syntax are dropped, so the typed text can never change the query.
// The text is matched without accents or case against fin_entries.search_text, which the database folds the same way.
export function foldText(s: string): string {
  return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
}

export function entrySearchFilter(raw: unknown): string | null {
  const term = foldText(String(raw ?? '')).replace(/[,()"\*%:]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80)
  if (!term) return null
  const parts = [`search_text.like."*${term}*"`]
  const money = /^(R\$\s?)?[\d.]+(\s?,\s?\d{1,2})?$/.test(String(raw ?? '').trim()) ? parseMoneyInput(String(raw).trim()) : null
  if (money && money !== 'invalid') parts.push(`amount.eq.${money}`)
  return parts.join(',')
}
