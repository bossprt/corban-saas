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

export async function readTabular(filename:string,buffer:Buffer):Promise<Record<string,unknown>[]>{
 if(/\.csv$/i.test(filename))return parseCsv(buffer.toString('utf8'))
 if(/\.xlsx$/i.test(filename))return parseXlsx(buffer)
 if(/\.xls$/i.test(filename)){
  const latin=buffer.toString('latin1')
  // Only HTML exported as .xls is supported; real binary BIFF is rejected instead of guessed.
  if(!/<table/i.test(latin))throw new ImportPipelineError('xls_binary_unsupported','XLS binário ainda não suportado; exporte como CSV')
  return parseHtmlTable(latin)
 }
 throw new ImportPipelineError('unsupported_format','Formato não suportado; use CSV, XLSX ou XLS HTML')
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
