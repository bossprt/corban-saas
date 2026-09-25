'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const PATH='/app/comercial/tipos-contrato'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const go=(c:FeedbackCode):never=>{revalidatePath(PATH);revalidatePath('/app/comercial/tabelas');revalidatePath('/app/simulacoes');return redirect(feedbackUrl(PATH,c))}
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
const manager=async()=>{const ctx=await requireAppContext();return atLeast(ctx.membership.role,'manager')?ctx:null}

export async function createContractType(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const name=text(f,'name')
 if(name.length<1||name.length>80)return go('erro:nome_invalido')
 const {error}=await ctx.supabase.from('contract_types').insert({
  organization_id:ctx.membership.organization_id,
  tech_key:`tenant_${crypto.randomUUID().replace(/-/g,'')}`,
  name,is_active:true,sort_order:1000
 })
 return error?go(classifyDbFeedback(error)):go('ok:tipo_contrato_cadastrado')
}

export async function saveContractTypeSettings(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const id=text(f,'contract_type_id')
 if(!uuid(id))return go('erro:catalogo_invalido')
 const payload={
  organization_id:ctx.membership.organization_id,
  contract_type_id:id,
  is_enabled:text(f,'is_enabled')==='on',
  use_in_pipeline:text(f,'use_in_pipeline')==='on',
  use_in_commission:text(f,'use_in_commission')==='on',
 }
 const {error}=await ctx.supabase.from('organization_contract_type_settings').upsert(payload,{onConflict:'organization_id,contract_type_id'})
 return error?go(classifyDbFeedback(error)):go('ok:tipo_contrato_atualizado')
}

export async function updateOwnContractType(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const id=text(f,'id'),name=text(f,'name'),active=text(f,'active')==='true'
 if(!uuid(id)||name.length<1||name.length>80)return go('erro:nome_invalido')
 const {error}=await ctx.supabase.from('contract_types').update({name,is_active:active}).eq('id',id).eq('organization_id',ctx.membership.organization_id)
 return error?go(classifyDbFeedback(error)):go('ok:tipo_contrato_atualizado')
}
