import { normalizeHeader } from '../commercial'
import { amountText, dateText, type ReceiptSheet } from '../receipts/parse'
import { LEGACY_FIELDS, type LegacyField, type LegacyMapping, type LegacyRow } from './fields'

export { LEGACY_FIELDS, LEGACY_ISSUE_LABEL, type LegacyField, type LegacyMapping, type LegacyRow } from './fields'

// Legacy base (F5.5): the columns of the previous system's export. The person importing points each field to a column;
// the aliases only pre-select the obvious ones. Values are converted here (money as decimal strings, dates as ISO); the
// database checks every row again and keeps its issue for the preview.
const MONEY: LegacyField[] = ['requested_amount', 'released_amount', 'installment_amount']
const DATES: LegacyField[] = ['contract_on', 'paid_on']

// Pre-selects each field whose column name is an obvious alias; a column is used once.
export function guessLegacyMapping(headers: string[]): LegacyMapping {
  const norm = headers.map(normalizeHeader)
  const used = new Set<number>()
  const out: LegacyMapping = {}
  for (const f of LEGACY_FIELDS) {
    const i = norm.findIndex((h, j) => !used.has(j) && f.aliases.includes(h))
    if (i >= 0) { out[f.key] = headers[i]; used.add(i) }
  }
  return out
}

// Rows for the database. A value that cannot be read is sent as it is, so the row shows "valor inválido" in the preview
// instead of being silently dropped. Blank lines are skipped.
export function buildLegacyRows(sheet: ReceiptSheet, mapping: LegacyMapping): LegacyRow[] {
  const col = new Map<LegacyField, number>()
  for (const [k, h] of Object.entries(mapping) as [LegacyField, string][]) {
    const i = sheet.headers.indexOf(h)
    if (h && i >= 0) col.set(k, i)
  }
  const rows: LegacyRow[] = []
  sheet.body.forEach((r, idx) => {
    if (!r.some(c => String(c ?? '').trim() !== '')) return
    const row: LegacyRow = { row: sheet.headerRow + idx + 1 }
    for (const [k, i] of col) {
      const raw = String(r[i] ?? '').trim()
      if (raw === '') continue
      if (MONEY.includes(k)) { const v = amountText(raw, false); row[k] = v === null ? undefined : ['invalid', 'ambiguous', 'negative'].includes(v) ? raw : v }
      else if (DATES.includes(k)) { const v = dateText(raw); row[k] = v === null ? undefined : v === 'invalid' ? raw : v }
      else row[k] = raw.slice(0, 200)
    }
    rows.push(row)
  })
  return rows
}
