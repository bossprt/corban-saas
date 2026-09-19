'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { prepareImport, ImportPipelineError, MAX_IMPORT_BYTES } from '@/lib/imports/pipeline'
import { TWOTECH_ADAPTER_KEY } from '@/lib/imports/twotech'
import { atLeast } from '@/lib/rbac'
import { buildBatchFindings } from '@/lib/imports/conflict-persist'

const semantics=new Set(['commercial_offer','production_report','commission_statement','payment_statement','network_payment_statement'])

function requiredText(formData:FormData,key:string,label:string){
 const value=String(formData.get(key)??'').trim()
 if(!value)throw new Error(`${label} é obrigatório`)
 return value
}

export async function createImportSource(formData:FormData){
 const {supabase,organization,membership,user}=await requireAppContext()
 if(!atLeast(membership.role,'manager'))throw new Error('Ação exige perfil administrador ou gerente')
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
 if(file.size>MAX_IMPORT_BYTES)throw new Error('Arquivo excede 10 MB')
 const {data:source}=await supabase.from('import_sources').select('id,financial_semantic,is_active').eq('id',sourceId).eq('organization_id',organization.id).maybeSingle()
 if(!source?.is_active)throw new Error('Fonte inválida ou inativa')
 let prepared
 try{
  prepared=await prepareImport({filename:file.name,mimeType:file.type,buffer:Buffer.from(await file.arrayBuffer()),sourceKey,sourceSemantic:source.financial_semantic})
 }catch(e){
  if(e instanceof ImportPipelineError)throw new Error(e.message)
  throw new Error('Não foi possível ler o arquivo')
 }
 const {adapter,rows:parsed,contentSha256,filename}=prepared
 const {data:batchId,error}=await supabase.rpc('ingest_normalized_import_batch',{
  p_source_id:sourceId,p_original_filename:filename,p_content_sha256:contentSha256,p_mime_type:file.type||'application/octet-stream',
  p_parser_key:adapter.key,p_parser_version:adapter.version,p_rows:parsed
 })
 if(error||!batchId)throw new Error('Falha na ingestão atômica do lote')
 // The RPC dedupes by SHA-256 per tenant. The same bytes under another source must not silently reuse a batch
 // whose source (and therefore governed financial semantic) differs from what the operator selected.
 const {data:ingested}=await supabase.from('import_batches').select('source_id').eq('id',batchId).maybeSingle()
 if(!ingested||ingested.source_id!==sourceId)throw new Error('Arquivo idêntico já importado em outra fonte; revise o lote existente')
 if(adapter.key===TWOTECH_ADAPTER_KEY){
  // Best-effort, write-once catalog lineage. Ingestion is idempotent by SHA-256, so a retry re-attaches safely;
  // until attach_import_batch_adapter is applied (see CURRENT-TASK gates) the RPC is absent and lineage stays null.
  await supabase.rpc('attach_import_batch_adapter',{p_batch_id:batchId,p_adapter_key:TWOTECH_ADAPTER_KEY})
 }
 const {error:matchError}=await supabase.rpc('generate_import_match_candidates',{p_batch_id:batchId})
 if(matchError)throw new Error('Lote ingerido, mas o matching determinístico falhou')
 // Persist detected conflicts (evidence-linked, advisory only). Best-effort: until import_conflicts_v1 is applied the RPC
 // does not exist and the batch page still recomputes conflicts on the fly; a failure here must not undo the ingestion.
 try{
  const {data:raws}=await supabase.from('import_raw_rows').select('id,row_number').eq('batch_id',batchId)
  const findings=buildBatchFindings(parsed,{organizationId:organization.id,sourceId,providerKey:adapter.key===TWOTECH_ADAPTER_KEY?'2tech':null,batchId},new Map((raws??[]).map(r=>[r.row_number as number,r.id as string])))
  if(findings.length)await supabase.rpc('record_import_conflicts',{p_batch_id:batchId,p_findings:findings})
 }catch{ /* advisory */ }
 // Server Actions bound directly to <form action> intentionally return void.
 revalidatePath('/app/importacoes')
}
