import ExcelJS from 'exceljs'

function cellValue(value:ExcelJS.CellValue):unknown{
 if(value===null||value===undefined)return ''
 if(value instanceof Date)return value.toISOString()
 if(typeof value==='object'){
  if('text' in value)return value.text
  if('result' in value)return value.result??''
  if('richText' in value)return value.richText.map(x=>x.text).join('')
 }
 return value
}

export async function parseXlsx(buffer:Buffer):Promise<Record<string,unknown>[]>{
 const workbook=new ExcelJS.Workbook()
 await workbook.xlsx.load(buffer)
 const sheet=workbook.worksheets[0]
 if(!sheet)throw new Error('xlsx_without_worksheet')
 let headerRow=0
 for(let n=1;n<=Math.min(sheet.rowCount,30);n++){
  const values=(sheet.getRow(n).values as ExcelJS.CellValue[]).slice(1).map(cellValue)
  if(values.filter(v=>String(v??'').trim()).length>=2){headerRow=n;break}
 }
 if(!headerRow)throw new Error('xlsx_header_not_found')
 const headers=(sheet.getRow(headerRow).values as ExcelJS.CellValue[]).slice(1).map(v=>String(cellValue(v)??'').trim())
 const rows:Record<string,unknown>[]=[]
 for(let n=headerRow+1;n<=sheet.rowCount;n++){
  const vals=(sheet.getRow(n).values as ExcelJS.CellValue[]).slice(1).map(cellValue)
  if(!vals.some(v=>String(v??'').trim()))continue
  const row:Record<string,unknown>={}
  headers.forEach((h,i)=>{if(h)row[h]=vals[i]??''})
  rows.push(row)
 }
 if(!rows.length)throw new Error('xlsx_without_rows')
 return rows
}
