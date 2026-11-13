import { normalizeHeader } from '../commercial'
import { pdfItemsToRows, type PdfItem, type PdfTableRules } from './smart-pdf'

// Banco Valor contracts from its commission report in PDF (owner request 03/11/2026: the bank sends no other file).
// The same column geometry as the receipt import. The report has no table column. Since 13/11/2026 (M.S. CONSULTORIA
// and Credimps reports) one report may carry several products: each one is a block with its product line ("CONSIG.
// EMPRESTIMO RORAIMA II"), the column titles, the contracts and "TOTAL PRODUTO"; a block may continue on the next page,
// where the product line and the titles are repeated. Every contract keeps the product of its block. The product only
// suggests the agreement (the owner confirms it on screen) and the table of each contract is picked by the owner,
// because the report does not say whether the client is "Comissionado" or "Efetivo".
export const VALOR_PDF_RULES: PdfTableRules = {
  isHeader: cells => {
    const h = cells.map(normalizeHeader)
    return h.includes('cpf') && h.includes('creditado') && h.includes('codigo')
  },
  isEnd: cells => /^total/.test(normalizeHeader(cells[0])),
  align: 'order',
}

export type ValorProduct = { label: string; hint: AgreementHint | null }
export type AgreementHint = { words: RegExp[]; not?: RegExp }

export const PDF_ERRORS: Record<string, string> = {
  pdf_no_text: 'O PDF é uma imagem (sem texto). Baixe o relatório de novo no portal do banco.',
  pdf_no_table: 'Não encontrei a tabela de contratos no PDF (linha de títulos com CPF, Creditado e Codigo).',
  pdf_ambiguous_layout: 'A tabela do PDF não está alinhada o bastante para ler com segurança.',
  pdf_too_large: 'PDF acima de 5 MB.',
  pdf_too_many_pages: 'PDF com mais de 30 páginas. Divida o relatório.',
  pdf_too_complex: 'PDF grande demais para ler.',
  pdf_unreadable: 'Não foi possível ler o PDF.',
}

const plain = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim()
const isProduct = (s: string) => /^consig\b/.test(plain(s))
const isPageNumber = (s: string) => /^pag\.?:?\s*\d+$/.test(plain(s))

// Words of the product line -> words of the company's agreement name. Only a suggestion: exactly one active agreement
// of the company must match, otherwise nothing is suggested and the owner chooses.
const HINTS: [RegExp, AgreementHint][] = [
  [/\brio branco\b/, { words: [/rio branco/] }],
  [/\bduque de caxias\b|\bpref\.? dq\b/, { words: [/caxias/] }],
  [/\bgov\.? sp\b|\bgoverno de sao paulo\b/, { words: [/sao paulo/, /\bgov/], not: /prefeitura/ }],
  [/\bmanaus/, { words: [/manaus/] }],
  [/\bsao luis\b/, { words: [/sao luis/] }],
  [/\broraima\b/, { words: [/roraima/] }],
  [/\bgoias\b/, { words: [/goias/], not: /prefeitura|goiania/ }],
  [/\bamazonas\b/, { words: [/amazonas/] }],
  [/\bacre\b/, { words: [/\bacre\b/] }],
  [/\bamapa\b/, { words: [/amapa/] }],
  [/\bmaranhao\b/, { words: [/maranhao/] }],
  [/\bpiaui\b/, { words: [/piaui/] }],
  [/\bsiape\b/, { words: [/siape/] }],
]
export const productHint = (label: string): AgreementHint | null => HINTS.find(([re]) => re.test(plain(label)))?.[1] ?? null

export function suggestAgreementId(hint: AgreementHint | null, agreements: readonly { id: string; name: string }[]): string | null {
  if (!hint) return null
  const hits = agreements.filter(a => { const n = plain(a.name); return hint.words.every(w => w.test(n)) && !(hint.not?.test(n)) })
  return hits.length === 1 ? hits[0].id : null
}

// Card or loan, from the product line of the report ("CONSIG. CARTAO BENEFICIO ...", "CONSIG. EMPRESTIMO ...") and from
// the name of a table ("Cartão Benefício ...", "Flex Cartão ...", "Consig. Pub I — Empréstimo", "Flex Goiás"). A product
// whose line says neither offers every table; a table without "cartão" in its name is a loan table.
export type ProductKind = 'card' | 'loan'
export const productKind = (label: string): ProductKind | null => { const t = plain(label); return /\bcartao\b/.test(t) ? 'card' : /\bemprestimo\b/.test(t) ? 'loan' : null }
export const tableKind = (name: string): ProductKind => (/\bcartao\b/.test(plain(name)) ? 'card' : 'loan')

// The product blocks of every page: the items between one product line and the next. Items above the first product
// line of a page continue the last product of the previous page. Page numbers ("Pag.: 1") are left out, so they never
// stick to a cell of the last contract of the page.
function blocks(pages: readonly (readonly PdfItem[])[]): { label: string; items: PdfItem[] }[] {
  const out: { label: string; items: PdfItem[] }[] = []
  for (const page of pages) {
    const items = page.filter(i => i.str.trim() && !isPageNumber(i.str))
    const starts = items.filter(i => isProduct(i.str)).sort((a, b) => b.y - a.y)
    const at = (y: number) => { let k = -1; for (let j = 0; j < starts.length; j++) if (y <= starts[j].y + 2.5) k = j; return k }
    const pageBlocks = starts.map(s => ({ label: s.str.trim(), items: [] as PdfItem[] }))
    const before: PdfItem[] = []
    for (const it of items) { if (isProduct(it.str)) continue; const k = at(it.y); (k < 0 ? before : pageBlocks[k].items).push(it) }
    if (before.length && out.length) out[out.length - 1].items.push(...before)
    out.push(...pageBlocks)
  }
  return out
}

export type ValorSheet = { rows: string[][]; products: ValorProduct[]; productOfRow: number[] } | { error: string }

// The report as the rows of a contract sheet (one header row, then the contracts): "-" (no net amount) becomes empty
// and every line is "Paga" (the report lists contracts credited to the client). productOfRow[i] is the product of
// rows[i + 1].
export function valorPdfSheet(pages: readonly (readonly PdfItem[])[]): ValorSheet {
  if (!pages.some(p => p.some(i => i.str.trim()))) return { error: PDF_ERRORS.pdf_no_text }
  const bs = blocks(pages)
  if (!bs.length) return { error: 'Não encontrei o produto do relatório (ex.: "CONSIG. EMPRESTIMO RIO BRANCO I").' }
  let header: string[] | null = null
  const body: string[][] = [], productOfRow: number[] = [], products: ValorProduct[] = []
  for (const b of bs) {
    const grid = pdfItemsToRows([b.items], VALOR_PDF_RULES)
    if (grid.issues.length) {
      // A block that ends at the bottom of a page has only its titles there: its contracts are on the next page.
      if (grid.issues[0].code === 'pdf_no_table' && !b.items.some(i => /^\d{11}$/.test(i.str.trim()))) continue
      const detail = grid.issues[0].detail ? ` ${grid.issues[0].detail}` : ''
      return { error: `${PDF_ERRORS[grid.issues[0].code] ?? PDF_ERRORS.pdf_unreadable}${detail} (produto ${b.label})` }
    }
    const [h, ...rows] = grid.rows
    if (header && h.map(normalizeHeader).join('|') !== header.map(normalizeHeader).join('|')) return { error: `${PDF_ERRORS.pdf_ambiguous_layout} As colunas mudam no produto ${b.label}.` }
    header ??= h
    let k = products.findIndex(p => p.label === b.label)
    if (k < 0) { products.push({ label: b.label, hint: productHint(b.label) }); k = products.length - 1 }
    for (const r of rows) { body.push([...r.map(c => (c.trim() === '-' ? '' : c)), 'Paga']); productOfRow.push(k) }
  }
  if (!header || !body.length) return { error: PDF_ERRORS.pdf_no_table }
  return { rows: [[...header, 'Etapa'], ...body], products, productOfRow }
}
