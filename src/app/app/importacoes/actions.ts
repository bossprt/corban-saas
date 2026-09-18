'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { sha256, selectImportAdapter, validateParsedRows } from '@/lib/imports/engine'
import { parseCsv, parseHtmlTable } from '@/lib/imports/tabular'

const managerRoles=new Set(['admin','manager'])
const semantics=new Set(['commercial_offer','production_report','commission_statement','payment_statement','network_payment_statement'])

function requiredText(formData:FormData,key:string,label:string){
 const value=String(formData.get(key)??'').trim()
 if(!value)throw new Error(`${label} é obrigatório`)
 return value
}

export async function createImportSource(formData:FormData){
 const {supabase,organization,membership,user}=await requireAppContext()
 if(!managerRoles.has(membership.role))throw new Error('Ação exige perfil administrador ou gerente')
 const name=requiredText(formData,'name','Nome da fonte')
 const sourceKind=requiredText(formData,'source_kind','Tipo da fonte')
 const financialSemantic=requiredText(formData,'financial_semantic','Semântica financeira')
 if(!['bank','correspondent','promotora','partner','legacy_system','manual','other'].includes(sourceKind))throw new Error('Tipo da fonte inválido')
 if(!semantics.has(financialSemantic))throw new Error('Semântica financeira inválida')
 const {error}=await supabase.from('import_sources').insert({
  organization_id:organization.id,name,source_kind:sourceKind,financial_semantic:financialSemantic,
  financial_semantic_reviewed_by:user.id,financial_semantic_reviewed_at:new Date().toISOString()
 })
 if(error)throw new Error('Não foi possível cadastrar a fonte de importação')
 revalidatePath('/app/importacoes')
}


export async function ingestImportFile(formData:FormData){
 const {supabase,organization}=await requireAppContext()
 const sourceId=requiredText(formData,'source_id','Fonte')
 const sourceKey=requiredText(formData,'source_key','Adapter')
 const file=formData.get('file')
 if(!(file instanceof File)||file.size===0)throw new Error('Arquivo obrigatório')
 if(file.size>10*1024*1024)throw new Error('Arquivo excede 10 MB')
 const {data:source}=await supabase.from('import_sources').select('id,financial_semantic,is_active').eq('id',sourceId).eq('organization_id',organization.id).maybeSingle()
 if(!source?.is_active)throw new Error('Fonte inválida ou inativa')
 const buffer=Buffer.from(await file.arrayBuffer())
 const filename=file.name
 let rows:Record<string,unknown>[]
 if(/\.csv$/i.test(filename))rows=parseCsv(buffer.toString('utf8'))
 else if(/\.xls$/i.test(filename)){
  const latin=buffer.toString('latin1')
  if(!/<table/i.test(latin))throw new Error('XLS binário ainda não suportado; exporte como CSV')
  rows=parseHtmlTable(latin)
 }else if(/\.xlsx$/i.test(filename))throw new Error('XLSX ainda não suportado neste parser; exporte como CSV')
 else throw new Error('Formato não suportado; use CSV ou XLS HTML')
 const adapter=selectImportAdapter({filename,mimeType:file.type,headers:Object.keys(rows[0]??{}),sourceKey})
 if(!adapter)throw new Error('Não foi possível determinar o adapter')
 if(source.financial_semantic!==adapter.financialSemantic&&adapter.financialSemantic==='commercial_offer')throw new Error('Fonte financeira não pode usar adapter de oferta comercial')
 const parsed=validateParsedRows(adapter.parse({filename,rows}))
 const {error}=await supabase.rpc('ingest_normalized_import_batch',{
  p_source_id:sourceId,p_original_filename:filename,p_content_sha256:sha256(buffer),p_mime_type:file.type||'application/octet-stream',
  p_parser_key:adapter.key,p_parser_version:adapter.version,p_rows:parsed
 })
 if(error)throw new Error('Falha na ingestão atômica do lote')
 revalidatePath('/app/importacoes')
}
