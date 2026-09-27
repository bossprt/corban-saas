import { csvDelimiter, parseDelimited } from '../commercial'

// Legacy base (F5.5): the file is read in the browser, so an export of any size (the 2tech one has 6 MB) never hits the
// request size limit of the server; only the chosen columns travel, in small blocks. XLSX/XLS through SheetJS (loaded
// only when needed), CSV/TXT as text.
export const LEGACY_FILE_MAX_BYTES = 30_000_000
export type LegacySheet = { headers: string[]; body: string[][]; headerRow: number; sha: string }

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
// Spreadsheet numbers become plain decimal text without float noise (0.1 + 0.2 never reaches the server).
export const cellText = (v: unknown): string => {
  if (v === null || v === undefined) return ''
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? '' : iso(v)
  if (typeof v === 'number') return Number.isFinite(v) ? String(Math.round(v * 1e6) / 1e6) : ''
  if (typeof v === 'boolean') return v ? 'Sim' : 'Não'
  return String(v).trim()
}

// The title line is the first of the first 30 with at least two filled cells (reports often start with a title).
export function splitSheet(rows: string[][]): Omit<LegacySheet, 'sha'> | null {
  const idx = rows.slice(0, 30).findIndex(r => r.filter(c => c !== '').length >= 2)
  if (idx < 0) return null
  return { headers: rows[idx].map(h => h.trim()), body: rows.slice(idx + 1), headerRow: idx + 1 }
}

export async function readLegacyFileInBrowser(file: File): Promise<LegacySheet | { error: string }> {
  if (file.size === 0) return { error: 'O arquivo está vazio.' }
  if (file.size > LEGACY_FILE_MAX_BYTES) return { error: 'Arquivo acima de 30 MB.' }
  const ext = file.name.toLowerCase().split('.').pop() ?? ''
  const buf = await file.arrayBuffer()
  const sha = hex(await crypto.subtle.digest('SHA-256', buf))
  let rows: string[][]
  if (ext === 'csv' || ext === 'txt') {
    let text = new TextDecoder('utf-8').decode(buf)
    if (text.includes('�')) text = new TextDecoder('windows-1252').decode(buf)
    rows = parseDelimited(text, csvDelimiter(text))
  } else if (ext === 'xlsx' || ext === 'xls') {
    try {
      const XLSX = await import('@e965/xlsx')
      const wb = XLSX.read(buf, { type: 'array', cellDates: true })
      const ws = wb.Sheets[wb.SheetNames[0]]
      const raw = XLSX.utils.sheet_to_json<unknown[]>(ws, { header: 1, raw: true, defval: '' })
      rows = raw.map(r => (r as unknown[]).map(cellText))
    } catch {
      return { error: 'Não foi possível ler a planilha.' }
    }
  } else {
    return { error: 'Formato não aceito. Envie XLSX, XLS ou CSV.' }
  }
  const sheet = splitSheet(rows)
  if (!sheet) return { error: 'Não encontrei a linha de títulos das colunas.' }
  return { ...sheet, sha }
}
