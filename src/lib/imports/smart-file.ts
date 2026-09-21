import { parseDelimited } from '../commercial'
import { xlsxRows } from '../commercial-xlsx'
import { fileExtension, inspectZip, sniffFormat } from './file-guards'
import { xlsRows } from './legacy-xls'
import { pdfRows, PDF_LIMITS } from './smart-pdf'
import { SMART_LIMITS, type SmartImportIssue } from './smart-commercial'

// ONE entry point that turns any supported upload into string[][]. The reader is chosen from the CONTENT (magic bytes), never from the name or MIME type.
// Supported: CSV/TXT, XLSX, legacy XLS (BIFF), PDF with a text layer. Everything else is refused. No format has its own commercial rules: they all feed mapSmartCommercialRows.
export const SMART_FILE_LIMITS = { bytes: 2_000_000, pdfBytes: PDF_LIMITS.bytes } as const
export type SmartFormat = 'csv' | 'xlsx' | 'xls' | 'pdf'
export type SmartFileRead = { format: SmartFormat | null; rows: string[][]; issues: SmartImportIssue[] }
const ALLOWED_EXT = new Set(['csv', 'txt', 'xlsx', 'xls', 'pdf'])
const fail = (code: string, format: SmartFormat | null = null, detail?: string): SmartFileRead => ({ format, rows: [], issues: [{ line: 1, code, detail }] })

export async function readSmartFile(bytes: Uint8Array, fileName: string): Promise<SmartFileRead> {
  if (bytes.length === 0) return fail('empty_file')
  if (!ALLOWED_EXT.has(fileExtension(fileName))) return fail('unsupported_file')
  const kind = sniffFormat(bytes)
  if (kind === 'pdf') {
    if (bytes.length > SMART_FILE_LIMITS.pdfBytes) return fail('file_too_large', 'pdf')
    const r = await pdfRows(bytes)
    return { format: 'pdf', rows: r.rows, issues: r.issues.map(i => ({ line: 1, code: i.code, detail: i.detail })) }
  }
  if (bytes.length > SMART_FILE_LIMITS.bytes) return fail('file_too_large')
  if (kind === 'zip') {
    const z = inspectZip(bytes)
    if (!z.ok) return fail(z.reason, 'xlsx')
    try {
      return { format: 'xlsx', rows: await xlsxRows(Buffer.from(bytes), SMART_LIMITS.sourceRows + 2, { rejectPercentFormat: true }), issues: [] }
    } catch (e) {
      if (e instanceof Error && e.message === 'xlsx_percent_number_format') return fail('percent_number_format', 'xlsx')
      return fail('xlsx_unreadable', 'xlsx')
    }
  }
  if (kind === 'ole') {
    const r = xlsRows(bytes)
    return { format: 'xls', rows: r.rows, issues: r.issues.map(i => ({ line: 1, code: i.code, detail: i.detail })) }
  }
  if (kind === 'html') return fail('html_disguised_as_excel')
  if (kind === 'binary') return fail('unsupported_file')
  return { format: 'csv', rows: parseDelimited(Buffer.from(bytes).toString('utf-8')), issues: [] }
}
