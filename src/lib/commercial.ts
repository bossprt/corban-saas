// Commercial helpers (pure, no I/O) shared by the imports and forms. The database is the authority and validates
// everything again. Money and percentages NEVER become a JavaScript float: they travel as canonical decimal STRINGS
// (PostgREST casts them to numeric).

// "1,85" | "1.85" | "1,85%" -> "1.85". Rejects thousands separators, exponents, signs and anything with more digits than the column can store.
export function parseDecimal(raw: unknown, opts: { maxInt: number; scale: number }): string | null {
  let t = String(raw ?? '').trim().replace(/%$/, '').trim()
  if (t === '') return null
  t = t.replace(',', '.')
  const m = /^(\d+)(?:\.(\d+))?$/.exec(t)
  if (!m) return null
  const int = m[1].replace(/^0+(?=\d)/, ''), frac = m[2] ?? ''
  if (int.length > opts.maxInt || frac.length > opts.scale) return null
  return frac ? `${int}.${frac}` : int
}
export const parseTerm = (raw: unknown): number | null => {
  const t = String(raw ?? '').trim()
  if (!/^\d{1,3}$/.test(t)) return null
  const n = Number(t)
  return n >= 1 && n <= 600 ? n : null
}

export const normalizeHeader = (s: unknown) => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')

// Minimal RFC-4180 reader: BOM, CRLF, quoted fields with "" escapes, delimiter chosen from the header (; , or tab).
// `delimiter` overrides the choice (bank reports start with a title line that has no delimiter at all).
// Delimiter of a CSV whose first lines may be a title block: the one that appears most across the first 30 lines.
// Ties go to ';' (Brazilian exports), because ',' is also the decimal separator of the amounts.
export function csvDelimiter(text: string): ';' | ',' | '\t' {
  const head = text.replace(/^﻿/, '').split(/\r?\n/).slice(0, 30).join('\n')
  const n = (c: string) => head.split(c).length - 1
  const semi = n(';'), tab = n('\t'), comma = n(',')
  if (semi > 0 && semi >= tab && semi >= comma) return ';'
  return tab > comma ? '\t' : ','
}

export function parseDelimited(text: string, delimiter?: ';' | ',' | '\t'): string[][] {
  const src = text.replace(/^﻿/, '')
  const firstLine = src.split(/\r?\n/, 1)[0] ?? ''
  const count = (c: string) => firstLine.split(c).length - 1
  const delim = delimiter ?? (count(';') >= count(',') && count(';') >= count('\t') && count(';') > 0 ? ';' : count('\t') > count(',') ? '\t' : ',')
  const rows: string[][] = []
  let row: string[] = [], cell = '', quoted = false
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (quoted) {
      if (c === '"') { if (src[i + 1] === '"') { cell += '"'; i++ } else quoted = false } else cell += c
    } else if (c === '"') quoted = true
    else if (c === delim) { row.push(cell); cell = '' }
    else if (c === '\n' || c === '\r') { if (c === '\r' && src[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = '' }
    else cell += c
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row) }
  return rows.filter(r => r.some(x => x.trim() !== ''))
}
