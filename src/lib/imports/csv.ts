// A CSV file as plain string rows, header included, blank rows skipped. Banks export with ";" (Excel in Portuguese) or
// ","; the header line decides. UTF-8 is read first; a file that is not valid UTF-8 is read as Windows-1252 (Excel's
// "CSV" save). Quoted fields may hold the separator, quotes ("") and line breaks.
export function csvRows(buffer: Uint8Array, maxRows = 1000): string[][] {
  let text: string
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(buffer) }
  catch { text = new TextDecoder('windows-1252').decode(buffer) }
  text = text.replace(/^﻿/, '')
  const firstLine = text.slice(0, text.search(/\r?\n|$/))
  const sep = (firstLine.match(/;/g)?.length ?? 0) >= (firstLine.match(/,/g)?.length ?? 0) ? ';' : ','

  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false
  const endRow = () => {
    row.push(cell)
    if (row.some(v => v.trim() !== '')) rows.push(row)
    row = []
    cell = ''
  }
  for (let i = 0; i < text.length && rows.length < maxRows; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++ }
      else if (ch === '"') quoted = false
      else cell += ch
    } else if (ch === '"' && cell === '') quoted = true
    else if (ch === sep) { row.push(cell); cell = '' }
    else if (ch === '\n') endRow()
    else if (ch !== '\r') cell += ch
  }
  if (cell !== '' || row.length) endRow()
  return rows.slice(0, maxRows)
}
