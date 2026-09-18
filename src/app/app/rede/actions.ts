'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

const managerRoles=new Set(['admin','manager'])

function requiredText(formData:FormData,key:string,label:string){
 const value=String(formData.get(key)??'').trim()
 if(!value) throw new Error(`${label} é obrigatório`)
 return value
}

function optionalText(formData:FormData,key:string){
 const value=String(formData.get(key)??'').trim()
 return value||null
}

async function requireCommercialManager(){
 const ctx=await requireAppContext()
 if(!managerRoles.has(ctx.membership.role)) throw new Error('Ação exige perfil administrador ou gerente')
 return ctx
}

export async function createCommercialEntity(formData:FormData){
 const {supabase,organization}=await requireCommercialManager()
 const legalName=requiredText(formData,'legal_name','Razão social/nome')
 const tradeName=optionalText(formData,'trade_name')
 const taxIdRaw=optionalText(formData,'tax_id')
 const taxId=taxIdRaw?.replace(/\D/g,'')||null
 const entityKind=requiredText(formData,'entity_kind','Tipo')
 if(!['bank','correspondent','promotora','partner','broker','indicator','association','other'].includes(entityKind)) throw new Error('Tipo inválido')
 if(taxId && ![11,14].includes(taxId.length)) throw new Error('CPF/CNPJ inválido')

 const {error}=await supabase.from('commercial_entities').insert({
  organization_id:organization.id,legal_name:legalName,trade_name:tradeName,tax_id:taxId,
  entity_kind:entityKind,is_internal:formData.get('is_internal')==='on'
 })
 if(error) throw new Error(error.code==='23505'?'Entidade já cadastrada neste tenant':'Não foi possível cadastrar a entidade')
 revalidatePath('/app/rede')
}

export async function createCommercialRelationship(formData:FormData){
 const {supabase,organization}=await requireCommercialManager()
 const upstream=requiredText(formData,'upstream_entity_id','Entidade acima')
 const downstream=requiredText(formData,'downstream_entity_id','Entidade abaixo')
 if(upstream===downstream) throw new Error('As entidades da relação devem ser diferentes')
 const role=requiredText(formData,'relationship_role','Papel')
 if(!['master','subestablished','partner','broker','indicator','other'].includes(role)) throw new Error('Papel inválido')
 const bankId=optionalText(formData,'bank_id')
 const effectiveFrom=requiredText(formData,'effective_from','Início da vigência')
 const {error}=await supabase.from('commercial_relationships').insert({
  organization_id:organization.id,upstream_entity_id:upstream,downstream_entity_id:downstream,
  bank_id:bankId,relationship_role:role,effective_from:new Date(effectiveFrom).toISOString()
 })
 if(error) throw new Error('Não foi possível cadastrar a relação comercial')
 revalidatePath('/app/rede')
}

export async function createCommercialChannel(formData:FormData){
 const {supabase,organization}=await requireCommercialManager()
 const name=requiredText(formData,'name','Nome do canal')
 const bankId=requiredText(formData,'bank_id','Banco')
 const {error}=await supabase.from('commercial_channels').insert({
  organization_id:organization.id,bank_id:bankId,name,
  relationship_id:optionalText(formData,'relationship_id'),
  external_partner_code:optionalText(formData,'external_partner_code'),
  payer_entity_id:optionalText(formData,'payer_entity_id')
 })
 if(error) throw new Error('Não foi possível cadastrar o canal comercial')
 revalidatePath('/app/rede')
}


export async function publishCommissionRule(formData:FormData){
 const {supabase}=await requireCommercialManager()
 const percentage=optionalText(formData,'percentage'),fixed=optionalText(formData,'fixed_amount'),factor=optionalText(formData,'anticipation_factor')
 const {error}=await supabase.rpc('create_and_publish_commission_rule',{
  p_channel_id:requiredText(formData,'channel_id','Canal'),p_product_table_id:requiredText(formData,'product_table_id','Tabela'),
  p_component_type:requiredText(formData,'component_type','Componente'),p_percentage:percentage?Number(percentage):null,p_fixed_amount:fixed?Number(fixed):null,
  p_anticipation_factor:factor?Number(factor):null,p_calculation_base:optionalText(formData,'calculation_base')??'proposal_amount',
  p_effective_from:new Date(requiredText(formData,'effective_from','Vigência')).toISOString(),p_operation_type:optionalText(formData,'operation_type')
 })
 if(error)throw new Error('Não foi possível publicar a regra de comissão')
 revalidatePath('/app/rede')
}

export async function publishSplitRule(formData:FormData){
 const {supabase}=await requireCommercialManager()
 const downstream=Number(requiredText(formData,'downstream_percentage','Repasse downstream'))/100
 const {error}=await supabase.rpc('create_and_publish_split_rule',{
  p_relationship_id:requiredText(formData,'relationship_id','Relação'),p_bank_id:optionalText(formData,'bank_id'),
  p_product_table_id:optionalText(formData,'product_table_id'),p_component_type:optionalText(formData,'component_type'),
  p_downstream_share:downstream,p_payment_flow:requiredText(formData,'payment_flow','Fluxo de pagamento'),
  p_effective_from:new Date(requiredText(formData,'effective_from','Vigência')).toISOString()
 })
 if(error)throw new Error('Não foi possível publicar a regra de split')
 revalidatePath('/app/rede')
}
