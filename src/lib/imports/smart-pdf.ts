import { SMART_HEADER_ALIASES } from './smart-commercial'
import { normalizeHeader } from '../commercial'

// PDF with a real TEXT layer and a table with a header row -> the SAME string[][] shape as CSV/XLSX. Deterministic geometry only: no OCR, no AI, no guessing.
// Anything that does not align cleanly is refused with a "needs review" code; a value, unit, term or contract type is NEVER inferred from context.
export type PdfItem = { str: string; x: number; y: number; w: number }
export type PdfGridResult = { rows: string[][]; issues: { code: string; detail?: string }[] }
export const PDF_LIMITS = { bytes: 5_000_000, pages: 30, items: 60_000 } as const

const LINE_TOL = 2.5, CELL_GAP = 6, COL_TOL = 3
const KNOWN = new Set(Object.values(SMART_HEADER_ALIASES).flat() as string[])
type Cell = { text: string; x0: number; x1: number; y: number }

function toLines(items: readonly PdfItem[]): Cell[][] {
  const clean = items.filter(i => i.str.trim() !== '').sort((a, b) => b.y - a.y || a.x - b.x)
  const lines: PdfItem[][] = []
  for (const it of clean) {
    const last = lines[lines.length - 1]
    if (last && Math.abs(last[0].y - it.y) <= LINE_TOL) last.push(it); else lines.push([it])
  }
  return lines.map(l => {
    const sorted = [...l].sort((a, b) => a.x - b.x)
    const cells: Cell[] = []
    for (const it of sorted) {
      const prev = cells[cells.length - 1]
      if (prev && it.x - prev.x1 < CELL_GAP) { prev.text += (it.x - prev.x1 > 0.8 ? ' ' : '') + it.str.trim(); prev.x1 = it.x + it.w }
      else cells.push({ text: it.str.trim(), x0: it.x, x1: it.x + it.w, y: it.y })
    }
    return cells
  })
}
const isHeaderLine = (cells: readonly Cell[]) => cells.filter(c => KNOWN.has(normalizeHeader(c.text))).length >= 4
const overlap = (a0: number, a1: number, b0: number, b1: number) => Math.max(0, Math.min(a1, b1) - Math.max(a0, b0))

export function pdfItemsToRows(pages: readonly (readonly PdfItem[])[]): PdfGridResult {
  const fail = (code: string, detail?: string): PdfGridResult => ({ rows: [], issues: [{ code, detail }] })
  if (!pages.some(p => p.some(i => i.str.trim()))) return fail('pdf_no_text') // scanned/image PDF: OCR is a separate, explicit future step
  let header: Cell[] | null = null
  const rows: string[][] = []
  for (const [pi, page] of pages.entries()) {
    const lines = toLines(page)
    let cols: Cell[] | null = null
    let proseAt: string | null = null // prose/footer line seen inside the table area: data after it means the line was NOT a footer
    let lastY: number | null = null, pitch = Infinity // vertical distance between table lines: a footer is detached from the table, an overflowing last row is not
    const detached = (y: number) => lastY !== null && Number.isFinite(pitch) && lastY - y > 1.8 * pitch
    for (const cells of lines) {
      if (isHeaderLine(cells)) {
        const key = cells.map(c => normalizeHeader(c.text)).join('|')
        if (header && header.map(c => normalizeHeader(c.text)).join('|') !== key) return fail('pdf_ambiguous_layout', `A tabela muda de colunas na página ${pi + 1}.`)
        if (!header) { header = cells; rows.push(cells.map(c => c.text)) }
        cols = cells; lastY = cells[0].y; pitch = Infinity
        continue
      }
      if (!cols) continue // text before the header (titles, notes) is never data
      const out: string[] = cols.map(() => '')
      const hit = cells.map(c => cols!.map((h, i) => ({ i, o: overlap(c.x0 - COL_TOL, c.x1 + COL_TOL, h.x0, h.x1) })).filter(x => x.o > 0))
      const aligned = hit.filter(h => h.length > 0).length
      if (aligned === 0) { if (!detached(cells[0].y)) return fail('pdf_ambiguous_layout', `Texto solto colado à tabela, página ${pi + 1}: "${cells[0].text.slice(0, 50)}".`); proseAt ??= cells[0].text; continue }
      // a single wide line that spills past its column is prose (footer, note); a narrow leftover is a WRAPPED CELL and must not be dropped silently
      if (cells.length === 1 && (hit[0].length >= 2 || cells[0].x1 - cells[0].x0 > cols[hit[0][0].i].x1 - cols[hit[0][0].i].x0 + 2 * COL_TOL)) { if (!detached(cells[0].y)) return fail('pdf_ambiguous_layout', `Texto largo colado à tabela, página ${pi + 1}: "${cells[0].text.slice(0, 50)}".`); proseAt ??= cells[0].text; continue }
      if (aligned < 2 || aligned !== cells.length) return fail('pdf_ambiguous_layout', `Linha da página ${pi + 1} não se alinha às colunas: "${cells.map(c => c.text).join(' ').slice(0, 80)}".`)
      for (const [k, h] of hit.entries()) {
        if (h.length !== 1) return fail('pdf_ambiguous_layout', `Uma célula da página ${pi + 1} toca duas colunas: "${cells[k].text.slice(0, 40)}".`)
        if (out[h[0].i] !== '') return fail('pdf_ambiguous_layout', `Duas células na mesma coluna, página ${pi + 1}.`)
        out[h[0].i] = cells[k].text
      }
      if (proseAt) return fail('pdf_ambiguous_layout', `Uma linha de texto solto ("${proseAt.slice(0, 50)}") aparece no meio da tabela, página ${pi + 1}.`)
      if (lastY !== null && lastY - cells[0].y > 0) pitch = Math.min(pitch, lastY - cells[0].y)
      lastY = cells[0].y
      rows.push(out)
    }
  }
  if (!header) return fail('pdf_no_table')
  if (rows.length < 2) return fail('pdf_no_table')
  return { rows, issues: [] }
}

// Text layer via unpdf (pdf.js without a worker/canvas). Bounded: bytes, pages, text items. No script, no font loading, no network.
export async function extractPdfItems(bytes: Uint8Array): Promise<{ pages: PdfItem[][] } | { error: string }> {
  if (bytes.length > PDF_LIMITS.bytes) return { error: 'pdf_too_large' }
  try {
    const { getDocumentProxy } = await import('unpdf')
    const pdf = await getDocumentProxy(new Uint8Array(bytes), { isEvalSupported: false, useSystemFonts: false, disableFontFace: true, verbosity: 0, enableXfa: false } as never)
    if (pdf.numPages > PDF_LIMITS.pages) return { error: 'pdf_too_many_pages' }
    const pages: PdfItem[][] = []
    let count = 0
    for (let n = 1; n <= pdf.numPages; n++) {
      const tc = await (await pdf.getPage(n)).getTextContent()
      const items: PdfItem[] = []
      for (const it of tc.items as { str?: string; transform?: number[]; width?: number }[]) {
        if (typeof it.str !== 'string' || !it.transform) continue
        items.push({ str: it.str, x: it.transform[4], y: it.transform[5], w: typeof it.width === 'number' ? it.width : it.str.length * 4 })
        if (++count > PDF_LIMITS.items) return { error: 'pdf_too_complex' }
      }
      pages.push(items)
    }
    return { pages }
  } catch { return { error: 'pdf_unreadable' } }
}

export async function pdfRows(bytes: Uint8Array): Promise<PdfGridResult> {
  const r = await extractPdfItems(bytes)
  if ('error' in r) return { rows: [], issues: [{ code: r.error }] }
  return pdfItemsToRows(r.pages)
}
