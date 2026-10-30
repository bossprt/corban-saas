import { normalizeHeader } from '../commercial'

// Commission table a sub-corban downloads from the Bevicred portal ("parceirotabelacomissao", 30/10/2026): an HTML page
// saved with an .xls name, two header rows (Taxa and the commission groups are column groups), one line per bank table
// and term. People also open it in Excel and save it as .xlsx or .csv: every format becomes the same grid of cells (a
// merged cell repeats its text) and is read by bevicredGridRows. The result is the Corban layout (Convênio, Tabela, ...)
// and then goes through mapSmartCommercialRows like any other file.
// Two layouts are known:
// - C6 (INSS): "Comissão Banco" (what the bank pays Bevicred, not this company's money, left out) and "Comissão
//   Bevicred" (what the sub receives); contract type from words of the table name; "Forma Contrato" empty.
// - Daycoval Gov. Acre: only "Comissão" (Total, Vista) and "Diferido" (Total, Mensal), which are the sub's own;
//   contract type written in "Forma Contrato".
// The bank is not in the file: the person importing chooses it. Convênio and contract type come from fixed words (below);
// anything that does not match exactly refuses the file, nothing is guessed.
export type BevicredRead = { rows: string[][] } | { error: string; detail?: string }

export const BEVICRED_HEADER = ['Convênio', 'Tabela', 'Código no banco', 'Vigência inicial', 'Tipo de contrato', 'Prazo inicial', 'Prazo final', 'Taxa', 'À vista', 'Diferido']

// Contract type by words of the table name: the most specific first.
const CONTRACT_RULES: [RegExp, string][] = [
  [/\bREFIN DA PORTABILIDADE\b/, 'refin_portabilidade'],
  [/\bPORTABILIDADE\b/, 'portabilidade'],
  [/\bREFIN\b/, 'refinanciamento'],
  [/\bNOVO\b/, 'novo'],
]
// Contract type written in "Forma Contrato"; "Transferência" is a debt purchase (owner, 30/10/2026).
const FORM_RULES: Record<string, string> = {
  NOVO: 'novo', REFIN: 'refinanciamento', PORTABILIDADE: 'portabilidade', 'REFIN DA PORTABILIDADE': 'refin_portabilidade', TRANSFERENCIA: 'compra_de_divida',
}
const AGREEMENT_RULES: [RegExp, string][] = [[/\bINSS\b/, 'INSS'], [/\bGOV(ERNO)? ACRE\b/, 'GOV ACRE']]
const plain = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim().toUpperCase()

// Accented letters as named entities (&atilde;, &ccedil;, ...), the way some exports write Portuguese.
const MARKS: Record<string, string> = { acute: '́', grave: '̀', circ: '̂', tilde: '̃', cedil: '̧', uml: '̈' }
const accents = (s: string) => s.replace(/&([a-zA-Z])(acute|grave|circ|tilde|cedil|uml);/g, (_, l, m) => (l + MARKS[m]).normalize('NFC'))
const decode = (s: string) => accents(s)
  .replace(/<[^>]+>/g, ' ')
  .replace(/&nbsp;/gi, ' ').replace(/&amp;/gi, '&').replace(/&lt;/gi, '<').replace(/&gt;/gi, '>').replace(/&quot;/gi, '"')
  .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(Number(d)))
  .replace(/\s+/g, ' ').trim()
const span = (attrs: string, name: string) => {
  const m = new RegExp(`${name}\\s*=\\s*["']?(\\d+)`, 'i').exec(attrs)
  return m ? Math.min(50, Math.max(1, Number(m[1]))) : 1
}
// HTML table into a grid, each rowspan/colspan cell repeated in every position it covers.
export function htmlGrid(html: string): string[][] {
  const grid: string[][] = []
  for (const [y, tr] of [...html.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].entries()) {
    const row = (grid[y] ??= [])
    let x = 0
    for (const c of tr[1].matchAll(/<t([dh])([^>]*)>([\s\S]*?)<\/t\1>/gi)) {
      while (row[x] !== undefined) x++
      const text = decode(c[3]), rs = span(c[2], 'rowspan'), cs = span(c[2], 'colspan')
      for (let dy = 0; dy < rs; dy++) for (let dx = 0; dx < cs; dx++) (grid[y + dy] ??= [])[x + dx] = text
      x += cs
    }
  }
  return grid.map(r => Array.from(r, c => c ?? ''))
}

const isHeaderRow = (r: string[]) => {
  const h = new Set(r.map(c => normalizeHeader(String(c ?? ''))))
  return ['descricao_banco', 'data_de_alteracao', 'convenio', 'forma_contrato'].every(k => h.has(k))
}
const HEADER_SEARCH = 5
export const isBevicredGrid = (rows: string[][]) => rows.slice(0, HEADER_SEARCH).some(isHeaderRow)

// Two header rows into one: "Comissão Bevicred" over "Vista" becomes "comissao_bevicred_vista"; a cell spanning both
// rows ("Prazo" over "Prazo", or over nothing when a spreadsheet leaves merged cells empty) keeps its own name.
function flatHeader(top: string[], sub: string[]): string[] {
  const t = [...top]
  for (let i = 1; i < t.length; i++) if (!t[i] && sub[i]) t[i] = t[i - 1]
  return t.map((c, i) => !sub[i] || sub[i] === c ? normalizeHeader(c) : `${normalizeHeader(c)}_${normalizeHeader(sub[i])}`)
}

// The page comes in ISO-8859-1 (Windows-1252), and so does a CSV saved by Excel; a file already in UTF-8 is kept as it is.
export function decodeTextBytes(bytes: Uint8Array): string {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes) } catch { return new TextDecoder('windows-1252').decode(bytes) }
}

const ZERO = /^0+([.,]0+)?$/
const amount = (raw: string) => raw.replace(',', '.')
const cents = (raw: string) => {
  const m = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(raw.trim())
  return m ? BigInt(m[1]) * BigInt(100) + BigInt((m[2] ?? '').padEnd(2, '0') || '0') : null
}
// A spreadsheet turns the date into a timestamp ("2026-06-16T00:00:00.000Z"): the day is what the table means.
const day = (raw: string) => /^\d{4}-\d{2}-\d{2}T/.test(raw) ? raw.slice(0, 10) : raw

export const bevicredTableRows = (html: string) => bevicredGridRows(htmlGrid(html))

export function bevicredGridRows(grid: string[][]): BevicredRead {
  const top = grid.slice(0, HEADER_SEARCH).findIndex(isHeaderRow)
  if (top < 0 || !grid[top + 1]) return { error: 'bevicred_layout_changed' }
  const cell = (c: unknown) => String(c ?? '').trim()
  const head = flatHeader(grid[top].map(cell), grid[top + 1].map(cell))
  const at = (...names: string[]) => names.map(n => head.indexOf(n)).find(i => i >= 0) ?? -1
  const rates = head.flatMap((h, i) => h.startsWith('taxa_') ? [i] : [])
  const col = {
    code: at('descricao_banco'), date: at('data_de_alteracao'), name: at('convenio'), form: at('forma_contrato'),
    rateFrom: rates.length === 2 ? rates[0] : -1, rateTo: rates.length === 2 ? rates[1] : -1, term: at('prazo'), total: at('comissao_total'),
    // "Comissão Bevicred" when the file also has the bank's columns; plain "Comissão"/"Diferido" otherwise
    upfront: at('comissao_bevicred_vista', 'comissao_vista'),
    deferred: at('comissao_bevicred_diferido_total', 'diferido_total'),
    monthly: at('comissao_bevicred_diferido_mensal', 'diferido_mensal'),
  }
  const missing = Object.entries(col).filter(([, i]) => i < 0).map(([k]) => k)
  if (missing.length) return { error: 'bevicred_layout_changed', detail: missing.join(', ') }
  // The bank's own commission columns without the Bevicred ones would be read as the sub's money: never.
  if (head.some(h => h.startsWith('comissao_banco')) && !head.some(h => h.startsWith('comissao_bevicred'))) return { error: 'bevicred_layout_changed' }

  const rows: string[][] = [BEVICRED_HEADER]
  for (const [i, raw] of grid.slice(top + 2).entries()) {
    const r = raw.map(cell)
    if (r.every(x => !x)) continue
    const line = top + 3 + i
    if (r.length > head.length && r.slice(head.length).some(Boolean)) return { error: 'bevicred_layout_changed', detail: `linha ${line}` }
    while (r.length < head.length) r.push('')
    const name = plain(r[col.name])
    const form = plain(r[col.form])
    const type = form ? FORM_RULES[form] : CONTRACT_RULES.find(([re]) => re.test(name))?.[1]
    const agreement = AGREEMENT_RULES.filter(([re]) => re.test(name))
    if (form && !type) return { error: 'bevicred_contract_form', detail: r[col.form].slice(0, 30) }
    if (!type) return { error: 'bevicred_unknown_contract_type', detail: r[col.name].slice(0, 80) }
    if (agreement.length !== 1) return { error: 'bevicred_unknown_agreement', detail: r[col.name].slice(0, 80) }
    // A monthly deferred has no place in the Corban yet: never dropped in silence.
    if (r[col.monthly] && !ZERO.test(r[col.monthly])) return { error: 'bevicred_monthly_deferred', detail: r[col.name].slice(0, 80) }
    // "Comissão Total" is what Bevicred pays the sub: it must be the sum of the columns that are imported.
    const total = cents(r[col.total]), up = cents(r[col.upfront]), def = cents(r[col.deferred] || '0')
    if (total === null || up === null || def === null) return { error: 'bevicred_invalid_number', detail: `linha ${line}` }
    if (total !== up + def) return { error: 'bevicred_total_mismatch', detail: r[col.name].slice(0, 80) }
    const term = /^(\d{1,3})(?:\s*a\s*(\d{1,3}))?$/i.exec(r[col.term])
    if (!term) return { error: 'bevicred_invalid_number', detail: `prazo da linha ${line}` }
    // A rate range (portability: origin rate ~ new rate) has no single rate: the line goes without one.
    const rate = r[col.rateFrom] === r[col.rateTo] ? amount(r[col.rateFrom]) : ''
    rows.push([
      agreement[0][1],
      // the term at the end of the name ("... WEB 108X", "... WEB 1 A 108X") is the line, not the table
      r[col.name].replace(/\s+(\d{1,3}\s+A\s+)?\d{1,3}X$/i, '').trim(),
      r[col.code], day(r[col.date]), type, term[1], term[2] ?? term[1], rate,
      amount(r[col.upfront]), ZERO.test(r[col.deferred] || '0') ? '' : amount(r[col.deferred]),
    ])
  }
  if (rows.length < 2) return { error: 'file_without_rows' }
  return { rows }
}
