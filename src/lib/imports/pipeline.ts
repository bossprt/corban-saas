import { selectImportAdapter,sha256,validateParsedRows } from './engine'
import type { FinancialEvidenceSemantic,ImportAdapter,ParsedImportRow } from './contract'
import { parseCsv,parseHtmlTable } from './tabular'
import { parseXlsx } from './xlsx'

// Generic, provider-agnostic import pipeline: bytes -> tabular rows -> adapter -> validated ParsedImportRow[].
// Pure (no I/O besides parsing the given buffer); persistence, tenancy and RBAC stay in the server action + RLS/RPC.
// Raw rows are preserved verbatim by every adapter (rawPayload). Nothing here publishes truth of any kind.

export const MAX_IMPORT_BYTES=10*1024*1024

export class ImportPipelineError extends Error{
 constructor(readonly code:string,message:string){super(message);this.name='ImportPipelineError'}
}

export type PreparedImport={
 filename:string
 contentSha256:string
 adapter:ImportAdapter
 rows:ParsedImportRow[]
 headers:string[]
}

export type DetectedFormat='xlsx'|'xls_html'|'xls_binary'|'csv'

// Format comes from the CONTENT, not the file name: a renamed file must neither be mis-parsed nor slip past a check.
export function detectFormat(filename:string,buffer:Buffer):DetectedFormat{
 if(!/\.(csv|xlsx|xls)$/i.test(filename))throw new ImportPipelineError('unsupported_format','Formato não suportado; use CSV, XLSX ou XLS HTML')
 if(buffer.length>=4&&buffer[0]===0x50&&buffer[1]===0x4b&&buffer[2]===0x03&&buffer[3]===0x04)return 'xlsx'
 if(buffer.length>=8&&buffer.subarray(0,8).equals(Buffer.from([0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1])))return 'xls_binary'
 if(/<table/i.test(buffer.subarray(0,65536).toString('latin1')))return 'xls_html'
 if(/\.xlsx$/i.test(filename))throw new ImportPipelineError('invalid_xlsx','O arquivo não é um XLSX válido')
 return 'csv'
}

export async function readTabular(filename:string,buffer:Buffer):Promise<Record<string,unknown>[]>{
 switch(detectFormat(filename,buffer)){
  case 'xlsx':return parseXlsx(buffer)
  case 'xls_html':return parseHtmlTable(buffer.toString('latin1'))
  // Real binary BIFF is rejected instead of guessed.
  case 'xls_binary':throw new ImportPipelineError('xls_binary_unsupported','XLS binário ainda não suportado; exporte como CSV')
  default:return parseCsv(buffer.toString('utf8'))
 }
}

export async function prepareImport(input:{
 filename:string
 mimeType?:string|null
 buffer:Buffer
 sourceKey:string
 // Financial semantic governed (and frozen) on the tenant's import source.
 sourceSemantic:FinancialEvidenceSemantic|string
}):Promise<PreparedImport>{
 if(!input.buffer.length)throw new ImportPipelineError('empty_file','Arquivo vazio')
 if(input.buffer.length>MAX_IMPORT_BYTES)throw new ImportPipelineError('file_too_large','Arquivo excede 10 MB')
 let rows:Record<string,unknown>[]
 try{rows=await readTabular(input.filename,input.buffer)}
 catch(e){
  if(e instanceof ImportPipelineError)throw e
  throw new ImportPipelineError('unreadable_file',`Arquivo ilegível (${e instanceof Error?e.message:'erro desconhecido'})`)
 }
 const headers=[...new Set(rows.flatMap(r=>Object.keys(r)))]
 const adapter=selectImportAdapter({filename:input.filename,mimeType:input.mimeType,headers,sourceKey:input.sourceKey})
 if(!adapter)throw new ImportPipelineError('adapter_not_found','Não foi possível determinar o adapter')
 if(input.sourceSemantic!==adapter.financialSemantic)throw new ImportPipelineError('semantic_mismatch','Adapter incompatível com a semântica financeira governada da fonte')
 const parsed=validateParsedRows(adapter.parse({filename:input.filename,rows}))
 if(!parsed.length)throw new ImportPipelineError('no_rows','Nenhuma linha reconhecida')
 return {filename:input.filename,contentSha256:sha256(input.buffer),adapter,rows:parsed,headers}
}
