import { normalizeHeader } from '../commercial'
import type { PdfItem } from './smart-pdf'

// "Prazos e Comissões" PDF of Banco Valor (Valor Financiamentos, October 2026 edition, owner request 13/11/2026): one
// block per product (name, kind, public, optional "Obs.:") followed by "Parcelas | Comissão" and one line per term band
// ("6x – 12x  6%"). The PDF gives only the TOTAL commission; the owner's rule for Valor is upfront = min(total, 6%) and
// bonus = the rest. Nothing here is guessed: any line that does not fit the layout refuses the whole file.
// The PDF names the agreement only for some products (Goiás, Governo de SP, Duque de Caxias, SIAPE); the agreement of
// every product is confirmed on screen among the company's own active agreements.
export type ValorBand = { label: string; min: number; max: number; total: string; upfront: string; bonus: string }
export type ValorProduct = { key: string; table: string; kind: string; audience: string; note: string | null; hint: AgreementHint | null; bands: ValorBand[] }
export type AgreementHint = 'goias' | 'gov_sp' | 'caxias' | 'siape'
export type ValorPrazosRead = { products: ValorProduct[] } | { error: string; detail?: string }

export const VALOR_UPFRONT_CAP_HUNDREDTHS = 600 // 6,00%

const plain = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim()

// Text lines of every page, top to bottom; the cells of a line keep their x order.
function pageLines(items: readonly PdfItem[]): string[][] {
  const sorted = items.filter(i => i.str.trim()).sort((a, b) => b.y - a.y || a.x - b.x)
  const lines: PdfItem[][] = []
  for (const it of sorted) {
    const last = lines[lines.length - 1]
    if (last && Math.abs(last[0].y - it.y) <= 2.5) last.push(it); else lines.push([it])
  }
  return lines.map(l => l.sort((a, b) => a.x - b.x).map(i => i.str.replace(/\s+/g, ' ').trim()))
}

const isTitle = (l: string[]) => l.length === 1 && /^prazos e comissoes\b/.test(plain(l[0]))
const isBankLine = (l: string[]) => l.length === 1 && /^valor financiamentos?\b/.test(plain(l[0]))
const isFooter = (l: string[]) => /documento somente leitura/.test(plain(l.join(' '))) || (l.length === 1 && /^pagina \d+ de \d+$/.test(plain(l[0])))
const isIntro = (l: string[]) => l.length === 1 && /^consulte quanto de comissao/.test(plain(l[0]))
const isSource = (l: string[]) => l.length === 1 && /^fonte:/.test(plain(l[0]))
const isBandHeader = (l: string[]) => l.length === 2 && plain(l[0]) === 'parcelas' && plain(l[1]) === 'comissao'

// The layout is recognised by its first lines: the "Prazos e Comissões" title and the "Valor Financiamentos" line.
export function isValorPrazos(pages: readonly (readonly PdfItem[])[]): boolean {
  const first = pageLines(pages[0] ?? []).slice(0, 4)
  return first.some(isTitle) && first.some(isBankLine)
}

const TERM = /^(\d{1,3})x(?:\s*[–—-]\s*(\d{1,3})x)?$/i
const LEVEL = /^(efetivo [ivx]+)\s*[–—·-]\s*(\d{1,3})x$/i
const PCT = /^(\d{1,2})(?:,(\d{1,2}))?\s*%$/

// "10%" / "4,5%" as hundredths of a percent (integer arithmetic only: never floating point for money).
const hundredths = (raw: string): number | null => {
  const m = PCT.exec(raw.trim())
  if (!m) return null
  const v = Number(m[1]) * 100 + Number((m[2] ?? '').padEnd(2, '0'))
  return v > 0 && v <= 10000 ? v : null
}
export const pctText = (h: number) => (h % 100 === 0 ? String(h / 100) : `${Math.trunc(h / 100)},${String(h % 100).padStart(2, '0').replace(/0$/, '')}`)

function hintFor(table: string, note: string | null): AgreementHint | null {
  const t = plain(`${table} ${note ?? ''}`)
  if (/\bgoias\b/.test(t)) return 'goias'
  if (/\bgov sp\b|governo de sao paulo/.test(t)) return 'gov_sp'
  if (/duque de caxias/.test(t)) return 'caxias'
  if (/^siape\b/.test(plain(table))) return 'siape'
  return null
}

// One active agreement of the company that matches the product's hint, or none (then the person chooses).
export function suggestAgreement(hint: AgreementHint | null, agreements: readonly { id: string; name: string }[]): { id: string; name: string } | null {
  if (!hint) return null
  const test: Record<AgreementHint, (n: string) => boolean> = {
    goias: n => /\bgoias\b/.test(n) && !/prefeitura|goiania/.test(n),
    gov_sp: n => /sao paulo/.test(n) && /\bgov/.test(n) && !/prefeitura/.test(n),
    caxias: n => /caxias/.test(n),
    siape: n => /\bsiape\b/.test(n),
  }
  const hits = agreements.filter(a => test[hint](plain(a.name)))
  return hits.length === 1 ? hits[0] : null
}

export function valorPrazosProducts(pages: readonly (readonly PdfItem[])[]): ValorPrazosRead {
  if (!pages.some(p => p.some(i => i.str.trim()))) return { error: 'pdf_no_text' }
  const lines = pages.flatMap(p => pageLines(p)).filter(l => !isTitle(l) && !isBankLine(l) && !isFooter(l) && !isIntro(l) && !isSource(l))
  type Block = { text: string[]; rows: [string, string][] }
  const blocks: Block[] = []
  let current: Block | null = null, inBands = false
  for (const l of lines) {
    if (isBandHeader(l)) {
      if (!current || inBands) return { error: 'valor_prazos_layout', detail: 'Linha "Parcelas / Comissão" fora de um produto.' }
      inBands = true
      continue
    }
    if (l.length === 1) {
      if (!current || inBands) { current = { text: [], rows: [] }; blocks.push(current); inBands = false }
      current.text.push(l[0])
      continue
    }
    if (l.length === 2 && inBands && current) { current.rows.push([l[0], l[1]]); continue }
    return { error: 'valor_prazos_layout', detail: `Linha fora do formato: "${l.join(' ').slice(0, 80)}".` }
  }
  if (!blocks.length) return { error: 'valor_prazos_layout', detail: 'Nenhum produto encontrado.' }

  const products: ValorProduct[] = []
  for (const b of blocks) {
    const [name, kind, audience, ...rest] = b.text
    const note = rest.length === 1 && /^obs\.?:/i.test(rest[0]) ? rest[0].replace(/^obs\.?:\s*/i, '') : null
    if (!name || !kind || !audience || rest.length > 1 || (rest.length === 1 && note === null)) return { error: 'valor_prazos_layout', detail: `Produto com cabeçalho fora do formato: "${b.text.join(' / ').slice(0, 80)}".` }
    if (!b.rows.length) return { error: 'valor_prazos_layout', detail: `Produto sem faixas de parcelas: "${name}".` }
    // Goiás "Efetivo I – 36x": each level is its own table (same term, different commission).
    const byTable = new Map<string, ValorBand[]>()
    for (const [label, pct] of b.rows) {
      const total = hundredths(pct)
      if (total === null) return { error: 'valor_prazos_layout', detail: `Comissão inválida em "${name}": "${pct}".` }
      const level = LEVEL.exec(label), term = level ? null : TERM.exec(label)
      if (!level && !term) return { error: 'valor_prazos_layout', detail: `Parcelas inválidas em "${name}": "${label}".` }
      const min = Number(level ? level[2] : term![1]), max = level ? min : Number(term![2] ?? term![1])
      if (min < 1 || max < min || max > 600) return { error: 'valor_prazos_layout', detail: `Parcelas inválidas em "${name}": "${label}".` }
      const table = level ? `${name} – ${level[1].replace(/^efetivo/i, 'Efetivo').replace(/ ([ivx]+)$/i, (_, r: string) => ` ${r.toUpperCase()}`)}` : name
      const bands = byTable.get(table) ?? []
      if (bands.some(x => min <= x.max && x.min <= max)) return { error: 'valor_prazos_layout', detail: `Faixas de parcelas sobrepostas em "${table}".` }
      const upfront = Math.min(total, VALOR_UPFRONT_CAP_HUNDREDTHS)
      bands.push({ label: level ? `${min}x` : label.replace(/\s*[–—-]\s*/, ' – '), min, max, total: pctText(total), upfront: pctText(upfront), bonus: pctText(total - upfront) })
      byTable.set(table, bands)
    }
    for (const [table, bands] of byTable) {
      const key = normalizeHeader(table).slice(0, 80)
      if (products.some(p => p.key === key)) return { error: 'valor_prazos_layout', detail: `Produto repetido no PDF: "${table}".` }
      products.push({ key, table, kind, audience, note, hint: hintFor(table, note), bands })
    }
  }
  return { products }
}

export const VALOR_PRAZOS_HEADER = ['Banco', 'Convênio', 'Tabela', 'Tipo de contrato', 'Prazo inicial', 'Prazo final', 'À vista', 'Bônus']
export const AGREEMENT_PENDING = '(escolha o convênio)'

// The products as rows of the Corban layout, one copy per agreement the product goes to (the same PDF table is valid in
// every agreement the company marks). Contract type "Novo" (every product of this PDF is a new operation); a zero bonus
// stays empty (the component does not apply to that band). A product with no agreement yet keeps a placeholder.
export function valorPrazosRows(products: readonly ValorProduct[], bankName: string, agreementsOf: (key: string) => readonly string[]): string[][] {
  return [VALOR_PRAZOS_HEADER, ...products.flatMap(p => {
    const names = agreementsOf(p.key)
    return (names.length ? names : [AGREEMENT_PENDING]).flatMap(agreement => p.bands.map(b => [
      bankName, agreement, p.table, 'Novo', String(b.min), String(b.max), b.upfront, b.bonus === '0' ? '' : b.bonus,
    ]))
  })]
}
