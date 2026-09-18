'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'


export async function decideImportCandidate(formData:FormData){
 const {supabase,membership,organization,user}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor')) throw new Error('Ação exige perfil de supervisão')
 const batchId=String(formData.get('batch_id')??'')
 const normalizedRowId=String(formData.get('normalized_row_id')??'')
 const candidateId=String(formData.get('candidate_id')??'')
 const decision=String(formData.get('decision')??'')
 const reason=String(formData.get('reason')??'').trim()||null
 if(!batchId||!normalizedRowId||!candidateId)throw new Error('Decisão incompleta')
 if(!['approve','reject','human_required'].includes(decision))throw new Error('Decisão inválida')

 const {data:candidate,error:candidateError}=await supabase.from('import_match_candidates')
  .select('id,normalized_row_id,status,match_strength').eq('id',candidateId).eq('normalized_row_id',normalizedRowId).maybeSingle()
 if(candidateError||!candidate)throw new Error('Candidato não encontrado')
 if(decision==='approve'&&candidate.match_strength==='ambiguous')throw new Error('Matching ambíguo não pode ser aprovado diretamente')

 const {error}=await supabase.from('import_decisions').insert({
  organization_id:organization.id,batch_id:batchId,normalized_row_id:normalizedRowId,candidate_id:candidateId,
  decision,reason,decided_by:user.id
 })
 if(error)throw new Error('Não foi possível registrar a decisão')
 revalidatePath(`/app/importacoes/${batchId}`)
}


export async function applyApprovedImportMatch(formData:FormData){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor')) throw new Error('Ação exige perfil de supervisão')
 const batchId=String(formData.get('batch_id')??'')
 const decisionId=String(formData.get('decision_id')??'')
 if(!batchId||!decisionId)throw new Error('Aplicação incompleta')
 const {error}=await supabase.rpc('apply_approved_import_match',{p_decision_id:decisionId})
 if(error)throw new Error('Não foi possível aplicar o vínculo aprovado')
 revalidatePath(`/app/importacoes/${batchId}`)
 revalidatePath('/app/propostas')
}


export async function publishApprovedImportFinancialFact(formData:FormData){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))throw new Error('Ação exige perfil de supervisão')
 const batchId=String(formData.get('batch_id')??'')
 const decisionId=String(formData.get('decision_id')??'')
 if(!batchId||!decisionId)throw new Error('Publicação financeira incompleta')
 const {error}=await supabase.rpc('publish_financial_fact_from_import_decision',{p_decision_id:decisionId})
 if(error)throw new Error('Evidência não atende aos requisitos para publicação financeira')
 revalidatePath(`/app/importacoes/${batchId}`)
 revalidatePath('/app/financeiro')
}


export async function confirmPaidFromImport(formData:FormData){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))throw new Error('Ação exige perfil de supervisão')
 const batchId=String(formData.get('batch_id')??'')
 const decisionId=String(formData.get('decision_id')??'')
 if(!batchId||!decisionId)throw new Error('Evidência operacional incompleta')
 const {error}=await supabase.rpc('confirm_proposal_paid_from_import',{p_decision_id:decisionId})
 if(error)throw new Error('A evidência não atende aos requisitos para confirmar pagamento/liberação da proposta')
 revalidatePath(`/app/importacoes/${batchId}`)
 revalidatePath('/app/propostas')
 revalidatePath('/app/operacao')
}
