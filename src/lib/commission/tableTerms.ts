// The "Prazo (meses)" filter and "Prazos" column of the tables search (owner approval 06/11/2026). Each line of a table
// covers a range of terms (term_min..term_max; a single term when both are equal); a table accepts a term when any line
// of the version shown covers it.
export type TermRange = { min: number; max: number }

// The typed term: whole months from 1 to 999, or null when the field is empty or not a number.
export function readTerm(raw: string): number | null {
  const t = raw.trim()
  if (!/^\d{1,3}$/.test(t)) return null
  const n = Number(t)
  return n >= 1 ? n : null
}

export function acceptsTerm(ranges: TermRange[], term: number): boolean {
  return ranges.some(r => r.min <= term && term <= r.max)
}

// "72 a 96" over all lines, "84" when every line has the same single term, "—" with no lines.
export function termsLabel(ranges: TermRange[]): string {
  if (!ranges.length) return '—'
  const min = Math.min(...ranges.map(r => r.min)), max = Math.max(...ranges.map(r => r.max))
  return min === max ? String(min) : `${min} a ${max}`
}
