// The bank's "Fator Price" report (Daycoval layout, 08/10/2026): one sheet per bank table. "Convênio:" carries the
// bank's table code and short name ("745031  RFNGOVACRE1DIGPORTAB"), "TC:" the fee added to the amount, and the grid
// starts at "Data Base" with one column per term ("48 meses" ... "120 meses") and one line per business date.
// Pure: no I/O. Factors stay exact decimal strings (never a float).
import { parseDecimal } from '../commercial'

export type FactorPriceSheet = {
  code: string
  label: string
  employer: string
  dates: { date: string; entries: { term: number; factor: string }[] }[]
}
export type FactorPriceIssue = { sheet: string; message: string }

const DATE = /^(\d{2})\/(\d{2})\/(\d{4})$/
const TERM = /^(\d{1,3})\s*mes(es)?$/i
const factorOf = (raw: string): string | null => {
  let t = raw.trim().replace(/\s/g, '')
  if (t.includes(',')) t = t.replace(/\./g, '').replace(',', '.')
  const d = parseDecimal(t, { maxInt: 1, scale: 10 })
  return d && Number(d.replace('.', '')) > 0 && d.startsWith('0') ? d : null
}

// sheets: every worksheet as rows of cell strings (empty cells as '').
export function parseFactorPrice(sheets: { name: string; rows: string[][] }[]): { sheets: FactorPriceSheet[]; issues: FactorPriceIssue[] } {
  const out: FactorPriceSheet[] = [], issues: FactorPriceIssue[] = []
  for (const { name, rows } of sheets) {
    let code = '', label = '', employer = '', tc = '', header: { col: number; terms: Map<number, number> } | null = null
    const dates: FactorPriceSheet['dates'] = []
    // Merged cells repeat their value in every merged column: skip the label's own repeats.
    const valueAfter = (r: string[], i: number) => r.slice(i + 1).find(c => c.trim() !== '' && c.trim() !== r[i].trim())?.trim() ?? ''
    for (const r of rows) {
      const i = r.findIndex(c => c.trim() !== '')
      if (i < 0) continue
      const first = r[i].trim()
      if (/^conv\S*nio:?$/i.test(first)) {
        const m = /^([0-9A-Za-z._-]{1,30})\s+(.*)$/.exec(valueAfter(r, i))
        if (m) { code = m[1]; label = m[2].trim() }
      } else if (/^empregador:?$/i.test(first)) employer = valueAfter(r, i)
      else if (/^tc:?$/i.test(first)) tc = valueAfter(r, i)
      else if (/^data base$/i.test(first)) {
        const terms = new Map<number, number>()
        r.forEach((c, j) => { const m = TERM.exec(c.trim()); if (m && ![...terms.values()].includes(Number(m[1]))) terms.set(j, Number(m[1])) })
        header = { col: i, terms }
      } else if (header && i <= header.col + 1 && DATE.test(first)) {
        const [, dd, mm, yyyy] = DATE.exec(first)!
        const entries: { term: number; factor: string }[] = []
        for (const [j, term] of header.terms) {
          const raw = (r[j] ?? '').trim()
          if (!raw) continue
          const f = factorOf(raw)
          if (!f) { issues.push({ sheet: name, message: `Fator inválido em ${first}, ${term} meses: ${raw}` }); continue }
          entries.push({ term, factor: f })
        }
        if (entries.length) dates.push({ date: `${yyyy}-${mm}-${dd}`, entries })
      }
    }
    if (!code && !header) continue // a sheet that is not a Fator Price report (blank, notes)
    if (!code) { issues.push({ sheet: name, message: 'Sem "Convênio:" com o código da tabela.' }); continue }
    if (tc && !/^0+([.,]0+)?$/.test(tc.replace(/\s/g, ''))) { issues.push({ sheet: name, message: `Tabela ${code}: TC ${tc} diferente de zero; o simulador ainda não soma a TC. Não importada.` }); continue }
    if (!dates.length) { issues.push({ sheet: name, message: `Tabela ${code}: nenhuma data com fator.` }); continue }
    out.push({ code, label, employer, dates })
  }
  // The same table in two sheets or two files: only when identical.
  const byCode = new Map<string, FactorPriceSheet>()
  for (const s of out) {
    const prev = byCode.get(s.code)
    if (!prev) { byCode.set(s.code, s); continue }
    if (JSON.stringify(prev.dates) !== JSON.stringify(s.dates)) issues.push({ sheet: s.code, message: `Tabela ${s.code} aparece duas vezes com fatores diferentes. Mande só uma.` })
  }
  return { sheets: [...byCode.values()], issues }
}
