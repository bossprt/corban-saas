import { normalizeHeader } from '../commercial'
import { splitSheet, type LegacySheet } from '../legacy/browser-read'
import { pdfRows, PDF_LIMITS, type PdfTableRules } from '../imports/smart-pdf'

// Commission report in PDF (Banco Valor, 28/10/2026): the same table reader as the commercial import (text layer and
// column geometry only, no OCR, no guessing), with the header of a receipt report: a line with the contract column and
// a value column. The table ends at the bank's "TOTAL ..." block, which is never a line of the report.
export const RECEIPT_PDF_RULES: PdfTableRules = {
  isHeader: cells => {
    const h = cells.map(normalizeHeader).filter(Boolean)
    return h.length >= 4 && h.some(c => /^(contrato|ade|proposta|n_contrato|numero_contrato|n_proposta)$/.test(c)) && h.some(c => /comiss|valor/.test(c))
  },
  isEnd: cells => /^total/.test(normalizeHeader(cells[0])),
  align: 'order',
}

const PDF_ERRORS: Record<string, string> = {
  pdf_no_text: 'O PDF é uma imagem (sem texto). Peça ao banco o relatório em PDF de texto, Excel ou CSV.',
  pdf_no_table: 'Não encontrei a tabela do relatório no PDF (linha de títulos com Contrato e Comissão/Valor).',
  pdf_ambiguous_layout: 'A tabela do PDF não está alinhada o bastante para ler com segurança.',
  pdf_too_large: 'PDF acima de 5 MB.',
  pdf_too_many_pages: 'PDF com mais de 30 páginas. Divida o relatório.',
  pdf_too_complex: 'PDF grande demais para ler.',
  pdf_unreadable: 'Não foi possível ler o PDF.',
}

export async function readReceiptPdf(bytes: Uint8Array, sha: string): Promise<LegacySheet | { error: string }> {
  if (bytes.length > PDF_LIMITS.bytes) return { error: PDF_ERRORS.pdf_too_large }
  const r = await pdfRows(bytes, RECEIPT_PDF_RULES)
  if (r.issues.length) {
    const i = r.issues[0]
    return { error: `${PDF_ERRORS[i.code] ?? PDF_ERRORS.pdf_unreadable}${i.detail ? ` ${i.detail}` : ''}` }
  }
  const sheet = splitSheet(r.rows)
  return sheet ? { ...sheet, sha } : { error: PDF_ERRORS.pdf_no_table }
}
