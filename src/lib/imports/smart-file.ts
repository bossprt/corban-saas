import { parseDelimited } from '../commercial'
import { xlsxRows } from '../commercial-xlsx'
import { fileExtension, inspectZip, sniffFormat } from './file-guards'
import { xlsRows } from './legacy-xls'
import { extractPdfItems, pdfItemsToRows, PDF_LIMITS } from './smart-pdf'
import { isValorPrazos, valorPrazosProducts, type ValorProduct } from './valor-prazos'
import { bevicredGridRows, decodeTextBytes, htmlGrid, isBevicredGrid } from './bevicred-table'
import { SMART_LIMITS, type SmartImportIssue } from './smart-commercial'

// ONE entry point that turns any supported upload into string[][]. The reader is chosen from the CONTENT (magic bytes), never from the name or MIME type.
// Supported: CSV/TXT, XLSX, legacy XLS (BIFF), PDF with a text layer, Banco Valor's "Prazos e Comissões" PDF, the Bevicred commission table (HTML named .xls, or
// that table saved again as XLSX/XLS/CSV: recognised by its header, whatever the format). Everything else is refused. No format has its own commercial rules: they all feed mapSmartCommercialRows.
export const SMART_FILE_LIMITS = { bytes: 2_000_000, pdfBytes: PDF_LIMITS.bytes } as const
export type SmartFormat = 'csv' | 'xlsx' | 'xls' | 'pdf' | 'bevicred' | 'valor_prazos'
// valor: the products of Banco Valor's "Prazos e Comissões" PDF; their rows are built once the bank and agreements are chosen.
export type SmartFileRead = { format: SmartFormat | null; rows: string[][]; issues: SmartImportIssue[]; valor?: ValorProduct[] }
const ALLOWED_EXT = new Set(['csv', 'txt', 'xlsx', 'xls', 'pdf'])
const fail = (code: string, format: SmartFormat | null = null, detail?: string): SmartFileRead => ({ format, rows: [], issues: [{ line: 1, code, detail }] })
const bevicred = (grid: string[][]): SmartFileRead => {
  const r = bevicredGridRows(grid)
  return 'error' in r ? fail(r.error, 'bevicred', r.detail) : { format: 'bevicred', rows: r.rows, issues: [] }
}
const orBevicred = (read: SmartFileRead): SmartFileRead => !read.issues.length && isBevicredGrid(read.rows) ? bevicred(read.rows) : read

export async function readSmartFile(bytes: Uint8Array, fileName: string): Promise<SmartFileRead> {
  if (bytes.length === 0) return fail('empty_file')
  if (!ALLOWED_EXT.has(fileExtension(fileName))) return fail('unsupported_file')
  const kind = sniffFormat(bytes)
  if (kind === 'pdf') {
    if (bytes.length > SMART_FILE_LIMITS.pdfBytes) return fail('file_too_large', 'pdf')
    const items = await extractPdfItems(bytes)
    if ('error' in items) return fail(items.error, 'pdf')
    if (isValorPrazos(items.pages)) {
      const v = valorPrazosProducts(items.pages)
      return 'error' in v ? fail(v.error, 'valor_prazos', v.detail) : { format: 'valor_prazos', rows: [], issues: [], valor: v.products }
    }
    const r = pdfItemsToRows(items.pages)
    return { format: 'pdf', rows: r.rows, issues: r.issues.map(i => ({ line: 1, code: i.code, detail: i.detail })) }
  }
  if (bytes.length > SMART_FILE_LIMITS.bytes) return fail('file_too_large')
  if (kind === 'zip') {
    const z = inspectZip(bytes)
    if (!z.ok) return fail(z.reason, 'xlsx')
    let rows: string[][]
    try { rows = await xlsxRows(Buffer.from(bytes), SMART_LIMITS.sourceRows + 2) } catch { return fail('xlsx_unreadable', 'xlsx') }
    return orBevicred({ format: 'xlsx', rows, issues: [] })
  }
  if (kind === 'ole') {
    const r = xlsRows(bytes)
    return orBevicred({ format: 'xls', rows: r.rows, issues: r.issues.map(i => ({ line: 1, code: i.code, detail: i.detail })) })
  }
  if (kind === 'html') {
    // The only HTML accepted is the Bevicred table (no bank column: the bank is chosen on screen); any other is refused.
    const grid = htmlGrid(decodeTextBytes(bytes))
    return isBevicredGrid(grid) ? bevicred(grid) : fail('html_disguised_as_excel')
  }
  if (kind === 'binary') return fail('unsupported_file')
  return orBevicred({ format: 'csv', rows: parseDelimited(decodeTextBytes(bytes)), issues: [] })
}
