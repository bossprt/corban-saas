import ExcelJS from 'exceljs'

// First worksheet as plain string rows, header included. Unlike parseXlsx (imports) this keeps duplicate headers apart so mapConditionRows can refuse them.
// maxRows: the smart import passes its own ceiling + 2 so an oversized sheet is DETECTED (rows > limit) instead of silently cut; other callers keep the old 1000.
export async function xlsxRows(buffer: Buffer, maxRows = 1000): Promise<string[][]> {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(buffer as unknown as ExcelJS.Buffer)
  const sheet = wb.worksheets[0]
  if (!sheet) throw new Error('xlsx_without_worksheet')
  const text = (v: ExcelJS.CellValue): string => {
    if (v === null || v === undefined) return ''
    if (v instanceof Date) return v.toISOString()
    if (typeof v === 'object') {
      if ('text' in v) return String(v.text)
      if ('result' in v) return String(v.result ?? '')
      if ('richText' in v) return v.richText.map(x => x.text).join('')
    }
    return String(v)
  }
  const rows: string[][] = []
  for (let n = 1; n <= Math.min(sheet.rowCount, maxRows); n++) {
    // Array.from: ExcelJS rows are SPARSE (empty cells are holes); .map would skip the holes and leave undefined cells
    const vals = Array.from((sheet.getRow(n).values as ExcelJS.CellValue[]).slice(1), text)
    if (vals.some(v => v.trim() !== '')) rows.push(vals)
  }
  return rows
}

// Every worksheet as plain string rows (the bank's Fator Price report has one sheet per table).
export async function xlsxSheets(buffer: Buffer, maxRows = 200, maxSheets = 100): Promise<{ name: string; rows: string[][] }[]> {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(buffer as unknown as ExcelJS.Buffer)
  const text = (v: ExcelJS.CellValue): string => {
    if (v === null || v === undefined) return ''
    if (v instanceof Date) return v.toISOString()
    if (typeof v === 'object') {
      if ('text' in v) return String(v.text)
      if ('result' in v) return String(v.result ?? '')
      if ('richText' in v) return v.richText.map(x => x.text).join('')
    }
    return String(v)
  }
  return wb.worksheets.slice(0, maxSheets).map(sheet => {
    const rows: string[][] = []
    for (let n = 1; n <= Math.min(sheet.rowCount, maxRows); n++) rows.push(Array.from((sheet.getRow(n).values as ExcelJS.CellValue[]).slice(1), text))
    return { name: sheet.name, rows }
  })
}
