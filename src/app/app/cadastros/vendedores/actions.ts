'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { sendInvitationEmail } from '@/lib/team.server'

const PATH='/app/cadastros/vendedores'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const go=(code:FeedbackCode):never=>{revalidatePath(PATH);return redirect(feedbackUrl(PATH,code))}
const manager=async()=>{const ctx=await requireAppContext();return atLeast(ctx.membership.role,'manager')?ctx:null}
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
const tax=(v:string)=>{const d=v.replace(/\D/g,'');return d===''?null:(d.length===11||d.length===14?d:undefined)}

export async function createSeller(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const name=text(f,'name'),category=text(f,'seller_category'),commissionGroup=text(f,'commission_group_id')
  const taxId=tax(text(f,'tax_id'))
  if(name.length<1||name.length>160||!['pf','pj','sub'].includes(category)||!uuid(commissionGroup)||taxId===undefined)return go('erro:vendedor_invalido')
  const {error}=await ctx.supabase.from('commercial_sellers').insert({
    organization_id:ctx.membership.organization_id,name,seller_category:category,tax_id:taxId,
    commission_group_id:commissionGroup
  })
  return error?go(classifyDbFeedback(error)):go('ok:vendedor_cadastrado')
}

export async function updateSeller(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const id=text(f,'id'),name=text(f,'name'),category=text(f,'seller_category'),commissionGroup=text(f,'commission_group_id')
  const taxId=tax(text(f,'tax_id'))
  if(!uuid(id)||name.length<1||name.length>160||!['pf','pj','sub'].includes(category)||!uuid(commissionGroup)||taxId===undefined)return go('erro:vendedor_invalido')
  const {error}=await ctx.supabase.from('commercial_sellers').update({
    name,seller_category:category,tax_id:taxId,commission_group_id:commissionGroup
  }).eq('id',id)
  return error?go(classifyDbFeedback(error)):go('ok:vendedor_atualizado')
}

export async function setSellerActive(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const id=text(f,'id'),active=text(f,'active')==='true'
  if(!uuid(id))return go('erro:vendedor_invalido')
  const {error}=await ctx.supabase.from('commercial_sellers').update({is_active:active}).eq('id',id)
  return error?go(classifyDbFeedback(error)):go('ok:vendedor_atualizado')
}

// Portal access (F7): the database creates an invitation that carries the 'corretor' role and binds the seller on
// acceptance; the e-mail goes out through Supabase Auth.
export async function inviteSellerToPortal(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const id=text(f,'id'),email=text(f,'email').toLowerCase()
  if(!uuid(id)||!/^[^@\s]+@[^@\s]+$/.test(email))return go('erro:requisicao_invalida')
  const {error}=await ctx.supabase.rpc('invite_seller_to_portal',{p_seller:id,p_email:email})
  if(error){
    const m=error.message??''
    if(/portal_role_missing/.test(m))return go('erro:portal_papel')
    if(/seller_already_has_access/.test(m))return go('erro:portal_acesso_existente')
    return go(classifyDbFeedback(error))
  }
  const outcome=await sendInvitationEmail(email)
  return go(outcome==='failed'?'erro:portal_convite_email':'ok:portal_convite')
}
