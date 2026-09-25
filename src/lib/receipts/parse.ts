import { parseDelimited } from '../commercial'
import { xlsxRows } from '../commercial-xlsx'
import { fileExtension, inspectZip, sniffFormat } from '../imports/file-guards'
import { xlsRows } from '../imports/legacy-xls'
import { parseMoneyInput } from '../money-input'

// Commission reports of banks and promoters (F5): file -> header + rows of text -> lines for import_receipt_report.
// Money never goes through a JavaScript number: cells arrive as text and become exact decimal strings, and any value
// that is ambiguous or has more than two decimals is refused (the owner chose zero tolerance), never rounded.

export const RECEIPT_FILE_LIMITS = { bytes: 10_000_000, rows: 20_000 } as const
export type ReceiptKind = 'upfront' | 'deferred' | 'chargeback'
export type ReceiptMapping = { ade: string; amount: string; installment?: string; paid_on?: string; bank?: string }
export type ReceiptRow = { row: number; ade: string; amount: string; installment?: string; paid_on?: string; bank?: string }
export type ReceiptIssue = { row: number; code: 'amount_invalid' | 'amount_ambiguous' | 'amount_negative' | 'ade_missing' | 'installment_invalid' | 'date_invalid' }
export type ReceiptSheet = { headers: string[]; body: string[][]; headerRow: number }

const ALLOWED_EXT = new Set(['csv', 'txt', 'xlsx', 'xls'])

// First worksheet (or CSV) as text rows. The reader is chosen from the content, never from the file name.
export async function readReceiptFile(bytes: Uint8Array, fileName: string): Promise<{ rows: string[][]; error?: string }> {
  if (bytes.length === 0) return { rows: [], error: 'empty_file' }
  if (bytes.length > RECEIPT_FILE_LIMITS.bytes) return { rows: [], error: 'file_too_large' }
  if (!ALLOWED_EXT.has(fileExtension(fileName))) return { rows: [], error: 'unsupported_file' }
  const kind = sniffFormat(bytes)
  if (kind === 'zip') {
    const z = inspectZip(bytes)
    if (!z.ok) return { rows: [], error: z.reason }
    try { return { rows: await xlsxRows(Buffer.from(bytes), RECEIPT_FILE_LIMITS.rows + 50) } } catch { return { rows: [], error: 'xlsx_unreadable' } }
  }
  if (kind === 'ole') {
    const r = xlsRows(bytes)
    return r.issues.length ? { rows: [], error: r.issues[0].code } : { rows: r.rows }
  }
  if (kind === 'text') {
    const text = Buffer.from(bytes).toString('utf-8')
    return { rows: parseDelimited(text, csvDelimiter(text)) }
  }
  return { rows: [], error: 'unsupported_file' }
}

// Delimiter of a CSV whose first lines may be a title block: the one that appears most across the first 30 lines.
// Ties go to ';' (Brazilian exports), because ',' is also the decimal separator of the amounts.
export function csvDelimiter(text: string): ';' | ',' | '\t' {
  const head = text.replace(/^﻿/, '').split(/\r?\n/).slice(0, 30).join('\n')
  const n = (c: string) => head.split(c).length - 1
  const semi = n(';'), tab = n('\t'), comma = n(',')
  if (semi > 0 && semi >= tab && semi >= comma) return ';'
  return tab > comma ? '\t' : ','
}

// Header = first row among the first 30 with at least two filled cells (reports often start with a title block).
// Blank rows stay in the body so row numbers follow the file as read.
export function splitHeader(rows: string[][]): ReceiptSheet | null {
  const idx = rows.slice(0, 30).findIndex(r => r.filter(c => String(c ?? '').trim() !== '').length >= 2)
  if (idx < 0) return null
  const headers = rows[idx].map(h => String(h ?? '').trim())
  const body = rows.slice(idx + 1)
  return { headers, body, headerRow: idx + 1 }
}

// "600,00", "1.234,56", "R$ 600" (typed) or "600" / "11.67" / "1234.5" (numeric cells as text).
// A single dot followed by exactly three digits ("1.234") is either one thousand or 1.234 reais: refused as ambiguous.
export function amountText(raw: unknown, allowNegative: boolean): string | 'invalid' | 'ambiguous' | 'negative' | null {
  let s = String(raw ?? '').replace(/R\$|\s| /g, '')
  if (s === '') return null
  let negative = false
  if (/^\(.*\)$/.test(s)) { negative = true; s = s.slice(1, -1) }
  if (s.startsWith('-')) { negative = true; s = s.slice(1) }
  if (s.endsWith('-')) { negative = true; s = s.slice(0, -1) }
  if (negative && !allowNegative) return 'negative'
  if (/^\d+\.\d{3}$/.test(s)) return 'ambiguous'
  // Numeric cells may carry trailing zeros beyond the cents ("600.500" is not produced; "11.670" is not either, but be safe).
  const dotted = /^(\d+)\.(\d+)$/.exec(s)
  if (dotted && dotted[2].length > 2) {
    const frac = dotted[2].replace(/0+$/, '')
    if (frac.length > 2) return 'invalid'
    s = `${dotted[1]}.${frac}`
  }
  const v = parseMoneyInput(s)
  if (v === null || v === 'invalid') return 'invalid'
  if (/^0+\.00$/.test(v)) return 'invalid'
  return v
}

// "2026-09-10", "2026-09-10T00:00:00.000Z" (date cells) or "10/09/2026".
export function dateText(raw: unknown): string | 'invalid' | null {
  const s = String(raw ?? '').trim()
  if (s === '') return null
  let y: number, m: number, d: number
  const iso = /^(\d{4})-(\d{2})-(\d{2})(?:T.*)?$/.exec(s)
  const br = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s)
  if (iso) { y = +iso[1]; m = +iso[2]; d = +iso[3] } else if (br) { d = +br[1]; m = +br[2]; y = +br[3] } else return 'invalid'
  const dt = new Date(Date.UTC(y, m - 1, d))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return 'invalid'
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

// "3", "003", "3/120" (installment of total).
export function installmentText(raw: unknown): string | 'invalid' | null {
  const s = String(raw ?? '').trim()
  if (s === '') return null
  const m = /^0*(\d{1,4})(?:\s*\/\s*\d{1,4})?$/.exec(s)
  if (!m || m[1] === '0' || m[1] === '') return 'invalid'
  return String(Number(m[1]))
}

// Applies the column layout. Rows with neither contract nor amount are skipped (blank or title lines); a row with an
// amount but no contract (e.g. a "Total" line) is reported so the operator sees it, never imported silently.
export function buildReceiptRows(sheet: ReceiptSheet, mapping: ReceiptMapping, kind: ReceiptKind): { rows: ReceiptRow[]; issues: ReceiptIssue[]; skipped: number } {
  const col = (name?: string) => (name ? sheet.headers.indexOf(name) : -1)
  const c = { ade: col(mapping.ade), amount: col(mapping.amount), installment: col(mapping.installment), paid_on: col(mapping.paid_on), bank: col(mapping.bank) }
  const rows: ReceiptRow[] = []
  const issues: ReceiptIssue[] = []
  let skipped = 0
  sheet.body.forEach((r, i) => {
    const line = sheet.headerRow + 1 + i
    const cell = (k: number) => (k >= 0 ? String(r[k] ?? '').trim() : '')
    const ade = cell(c.ade)
    const amountRaw = cell(c.amount)
    if (!ade && !amountRaw) { skipped++; return }
    if (!ade) { issues.push({ row: line, code: 'ade_missing' }); return }
    const amount = amountText(amountRaw, kind === 'chargeback')
    if (amount === null || amount === 'invalid') { issues.push({ row: line, code: 'amount_invalid' }); return }
    if (amount === 'ambiguous') { issues.push({ row: line, code: 'amount_ambiguous' }); return }
    if (amount === 'negative') { issues.push({ row: line, code: 'amount_negative' }); return }
    const installment = installmentText(cell(c.installment))
    if (installment === 'invalid') { issues.push({ row: line, code: 'installment_invalid' }); return }
    const paidOn = dateText(cell(c.paid_on))
    if (paidOn === 'invalid') { issues.push({ row: line, code: 'date_invalid' }); return }
    const row: ReceiptRow = { row: line, ade: ade.slice(0, 60), amount }
    if (installment) row.installment = installment
    if (paidOn) row.paid_on = paidOn
    const bank = cell(c.bank)
    if (bank) row.bank = bank.slice(0, 120)
    rows.push(row)
  })
  return { rows, issues, skipped }
}

export const RECEIPT_ISSUE_LABEL: Record<ReceiptIssue['code'], string> = {
  amount_invalid: 'valor inválido ou com mais de dois decimais',
  amount_ambiguous: 'valor ambíguo (ex.: "1.234" pode ser mil reais ou 1,234): corrija no arquivo para "1.234,00"',
  amount_negative: 'valor negativo em relatório que não é de estorno',
  ade_missing: 'linha com valor e sem número do contrato (ADE)',
  installment_invalid: 'parcela inválida',
  date_invalid: 'data inválida',
}
