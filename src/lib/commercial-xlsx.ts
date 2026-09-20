import ExcelJS from 'exceljs'

// First worksheet as plain string rows, header included. Unlike parseXlsx (imports) this keeps duplicate headers apart so mapConditionRows can refuse them.
export async function xlsxRows(buffer: Buffer): Promise<string[][]> {
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
  for (let n = 1; n <= Math.min(sheet.rowCount, 1000); n++) {
    const vals = (sheet.getRow(n).values as ExcelJS.CellValue[]).slice(1).map(text)
    if (vals.some(v => v.trim() !== '')) rows.push(vals)
  }
  return rows
}
