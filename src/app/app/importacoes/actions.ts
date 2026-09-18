'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

const managerRoles=new Set(['admin','manager'])
const semantics=new Set(['commercial_offer','production_report','commission_statement','payment_statement','network_payment_statement'])

function requiredText(formData:FormData,key:string,label:string){
 const value=String(formData.get(key)??'').trim()
 if(!value)throw new Error(`${label} é obrigatório`)
 return value
}

export async function createImportSource(formData:FormData){
 const {supabase,organization,membership}=await requireAppContext()
 if(!managerRoles.has(membership.role))throw new Error('Ação exige perfil administrador ou gerente')
 const name=requiredText(formData,'name','Nome da fonte')
 const sourceKind=requiredText(formData,'source_kind','Tipo da fonte')
 const financialSemantic=requiredText(formData,'financial_semantic','Semântica financeira')
 if(!['bank','correspondent','promotora','partner','legacy_system','manual','other'].includes(sourceKind))throw new Error('Tipo da fonte inválido')
 if(!semantics.has(financialSemantic))throw new Error('Semântica financeira inválida')
 const {error}=await supabase.from('import_sources').insert({
  organization_id:organization.id,name,source_kind:sourceKind,financial_semantic:financialSemantic,
  financial_semantic_reviewed_by:membership.user_id,financial_semantic_reviewed_at:new Date().toISOString()
 })
 if(error)throw new Error('Não foi possível cadastrar a fonte de importação')
 revalidatePath('/app/importacoes')
}
