import { normalizeHeader } from '../commercial'

// Commission table a sub-corban downloads from the Bevicred portal ("parceirotabelacomissao", 30/10/2026): an HTML page
// saved with an .xls name, two header rows (Taxa, Comissão Banco and Comissão Bevicred are column groups), one line per
// bank table and term. It becomes the Corban layout (Banco, Convênio, Tabela, ...) and then goes through
// mapSmartCommercialRows like any other file.
// What the sub receives is "Comissão Bevicred"; the "Comissão Banco" columns are what the bank pays Bevicred, so they
// are not this company's money and are left out. The bank is not in the file: the person importing chooses it.
// Convênio and contract type come from fixed words of the table name (below); a name that does not match exactly
// one rule refuses the file, nothing is guessed.
export type BevicredRead = { rows: string[][] } | { error: string; detail?: string }

export const BEVICRED_HEADER = ['Convênio', 'Tabela', 'Código no banco', 'Vigência inicial', 'Tipo de contrato', 'Prazo inicial', 'Prazo final', 'Taxa', 'À vista', 'Diferido']

// Contract type by words of the table name: the most specific first.
const CONTRACT_RULES: [RegExp, string][] = [
  [/\bREFIN DA PORTABILIDADE\b/, 'refin_portabilidade'],
  [/\bPORTABILIDADE\b/, 'portabilidade'],
  [/\bREFIN\b/, 'refinanciamento'],
  [/\bNOVO\b/, 'novo'],
]
const AGREEMENT_RULES: [RegExp, string][] = [[/\bINSS\b/, 'INSS']]

type Cell = { text: string; rowspan: number; colspan: number }
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
function tableRows(html: string): Cell[][] {
  return [...html.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].map(tr =>
    [...tr[1].matchAll(/<t([dh])([^>]*)>([\s\S]*?)<\/t\1>/gi)].map(c => ({ text: decode(c[3]), rowspan: span(c[2], 'rowspan'), colspan: span(c[2], 'colspan') })))
}
// Two header rows into one: "Comissão Bevicred" over "Vista" becomes "comissao_bevicred_vista".
function flatHeader(top: Cell[], sub: Cell[]): string[] {
  const out: string[] = []
  let k = 0
  for (const c of top) {
    if (c.rowspan >= 2) { out.push(normalizeHeader(c.text)); continue }
    for (let i = 0; i < c.colspan; i++) out.push(`${normalizeHeader(c.text)}_${normalizeHeader(sub[k++]?.text)}`)
  }
  return out
}

export const isBevicredTable = (html: string) => { const t = accents(html); return /comiss[ãa]o\s+bevicred/i.test(t) && /conv[êe]nio/i.test(t) }

// The page comes in ISO-8859-1 (Windows-1252); a file already in UTF-8 is kept as it is.
export function decodeHtmlBytes(bytes: Uint8Array): string {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes) } catch { return new TextDecoder('windows-1252').decode(bytes) }
}

const ZERO = /^0+([.,]0+)?$/
const amount = (raw: string) => raw.replace(',', '.')
const cents = (raw: string) => {
  const m = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(raw.trim())
  return m ? BigInt(m[1]) * BigInt(100) + BigInt((m[2] ?? '').padEnd(2, '0') || '0') : null
}

export function bevicredTableRows(html: string): BevicredRead {
  const all = tableRows(html)
  const top = all.findIndex(r => r.some(c => /^comissao_bevicred$/.test(normalizeHeader(c.text))))
  if (top < 0 || !all[top + 1]) return { error: 'bevicred_layout_changed' }
  const head = flatHeader(all[top], all[top + 1])
  const at = (name: string) => head.indexOf(name)
  const col = {
    code: at('descricao_banco'), date: at('data_de_alteracao'), name: at('convenio'), form: at('forma_contrato'),
    rateFrom: at('taxa_inicial'), rateTo: at('taxa_final'), term: at('prazo'), total: at('comissao_total'),
    upfront: at('comissao_bevicred_vista'), deferred: at('comissao_bevicred_diferido_total'), monthly: at('comissao_bevicred_diferido_mensal'),
  }
  const missing = Object.entries(col).filter(([, i]) => i < 0).map(([k]) => k)
  if (missing.length) return { error: 'bevicred_layout_changed', detail: missing.join(', ') }

  const rows: string[][] = [BEVICRED_HEADER]
  for (const [i, tr] of all.slice(top + 2).entries()) {
    const r = tr.map(c => c.text)
    if (r.every(x => !x)) continue
    const line = top + 3 + i
    if (r.length !== head.length) return { error: 'bevicred_layout_changed', detail: `linha ${line}` }
    const name = r[col.name].toUpperCase()
    const type = CONTRACT_RULES.find(([re]) => re.test(name))?.[1]
    const agreement = AGREEMENT_RULES.filter(([re]) => re.test(name))
    if (!type) return { error: 'bevicred_unknown_contract_type', detail: r[col.name].slice(0, 80) }
    if (agreement.length !== 1) return { error: 'bevicred_unknown_agreement', detail: r[col.name].slice(0, 80) }
    if (r[col.form]) return { error: 'bevicred_contract_form', detail: r[col.form].slice(0, 30) }
    // A monthly deferred has no place in the Corban yet: never dropped in silence.
    if (r[col.monthly] && !ZERO.test(r[col.monthly])) return { error: 'bevicred_monthly_deferred', detail: r[col.name].slice(0, 80) }
    // "Comissão Total" is what Bevicred pays the sub: it must be the sum of the Bevicred columns that are imported.
    const total = cents(r[col.total]), up = cents(r[col.upfront]), def = cents(r[col.deferred] || '0')
    if (total === null || up === null || def === null) return { error: 'bevicred_invalid_number', detail: `linha ${line}` }
    if (total !== up + def) return { error: 'bevicred_total_mismatch', detail: r[col.name].slice(0, 80) }
    const term = /^(\d{1,3})(?:\s*a\s*(\d{1,3}))?$/i.exec(r[col.term].trim())
    if (!term) return { error: 'bevicred_invalid_number', detail: `prazo da linha ${line}` }
    // A rate range (portability: origin rate ~ new rate) has no single rate: the line goes without one.
    const rate = r[col.rateFrom] === r[col.rateTo] ? amount(r[col.rateFrom]) : ''
    rows.push([
      agreement[0][1],
      // the term at the end of the name ("... WEB 108X", "... WEB 1 A 108X") is the line, not the table
      r[col.name].replace(/\s+(\d{1,3}\s+A\s+)?\d{1,3}X$/i, '').trim(),
      r[col.code], r[col.date], type, term[1], term[2] ?? term[1], rate,
      amount(r[col.upfront]), ZERO.test(r[col.deferred] || '0') ? '' : amount(r[col.deferred]),
    ])
  }
  if (rows.length < 2) return { error: 'file_without_rows' }
  return { rows }
}
