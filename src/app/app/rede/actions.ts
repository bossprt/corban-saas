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
