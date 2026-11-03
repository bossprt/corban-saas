import { normalizeHeader } from '../commercial'
import { pdfItemsToRows, type PdfItem, type PdfTableRules } from './smart-pdf'

// Banco Valor contracts from its commission report in PDF (owner request 03/11/2026: the bank sends no other file).
// The same column geometry as the receipt import. The report has no table column; its product line ("CONSIG.
// EMPRESTIMO RIO BRANCO I") tells the agreement and the kind of table, and the owner picks the table on each line.
export const VALOR_PDF_RULES: PdfTableRules = {
  isHeader: cells => {
    const h = cells.map(normalizeHeader)
    return h.includes('cpf') && h.includes('creditado') && h.includes('codigo')
  },
  isEnd: cells => /^total/.test(normalizeHeader(cells[0])),
  align: 'order',
}

// Product lines known so far, after normalize. Another product refuses the file instead of guessing its agreement.
export type ValorProduct = { label: string; agreement: string; tablePrefix: string }
const PRODUCTS: [RegExp, Omit<ValorProduct, 'label'>][] = [
  [/^consig\.? emprestimo rio branco\b/, { agreement: 'Prefeitura de Rio Branco', tablePrefix: 'emprestimo' }],
]

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

// Text lines of a page, top to bottom, cells joined by a space.
function textLines(items: readonly PdfItem[]): string[] {
  const sorted = items.filter(i => i.str.trim()).sort((a, b) => b.y - a.y || a.x - b.x)
  const lines: PdfItem[][] = []
  for (const it of sorted) {
    const last = lines[lines.length - 1]
    if (last && Math.abs(last[0].y - it.y) <= 2.5) last.push(it); else lines.push([it])
  }
  return lines.map(l => l.sort((a, b) => a.x - b.x).map(i => i.str.trim()).join(' ').replace(/\s+/g, ' '))
}

export type ValorSheet = { rows: string[][]; product: ValorProduct } | { error: string }

// The report as the rows of a contract sheet: "-" (no net amount) becomes empty and every line is "Paga" (the report
// lists contracts credited to the client).
export function valorPdfSheet(pages: readonly (readonly PdfItem[])[]): ValorSheet {
  const products = [...new Set(pages.flatMap(p => textLines(p)).filter(l => /^consig\b/.test(plain(l))))]
  if (products.length === 0) return { error: 'Não encontrei o produto do relatório (ex.: "CONSIG. EMPRESTIMO RIO BRANCO I").' }
  if (products.length > 1) return { error: `O PDF tem mais de um produto (${products.join(', ')}). Gere um relatório por produto.` }
  const known = PRODUCTS.find(([re]) => re.test(plain(products[0])))
  if (!known) return { error: `O produto "${products[0]}" ainda não tem layout no Corban. Envie o PDF para ser cadastrado.` }
  const grid = pdfItemsToRows(pages, VALOR_PDF_RULES)
  if (grid.issues.length) return { error: `${PDF_ERRORS[grid.issues[0].code] ?? PDF_ERRORS.pdf_unreadable}${grid.issues[0].detail ? ` ${grid.issues[0].detail}` : ''}` }
  const [header, ...body] = grid.rows
  return {
    rows: [[...header, 'Etapa'], ...body.map(r => [...r.map(c => (c.trim() === '-' ? '' : c)), 'Paga'])],
    product: { label: products[0], ...known[1] },
  }
}
