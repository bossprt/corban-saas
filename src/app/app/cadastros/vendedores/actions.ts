'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { normalizeEmail } from '@/lib/team'
import { sendInvitationEmail } from '@/lib/team.server'

const PATH='/app/cadastros/vendedores'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const go=(code:FeedbackCode):never=>{revalidatePath(PATH);return redirect(feedbackUrl(PATH,code))}
const manager=async()=>{const ctx=await requireAppContext();return atLeast(ctx.membership.role,'manager')?ctx:null}
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
const pct=(v:string)=>{const s=v.trim().replace(',','.');if(!/^\\d{1,3}(?:\\.\\d{1,6})?$/.test(s))return null;const [whole,frac='']=s.split('.');const normalizedWhole=whole.replace(/^0+(?=\\d)/,'');if(normalizedWhole.length>3)return null;if(normalizedWhole.length===3&&normalizedWhole>'100')return null;if(normalizedWhole==='100'&&/[^0]/.test(frac))return null;return s}
const tax=(v:string)=>{const d=v.replace(/\D/g,'');return d===''?null:(d.length===11||d.length===14?d:undefined)}

export async function createSellerGroup(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const name=text(f,'name')
  if(name.length<1||name.length>80)return go('erro:nome_invalido')
  const {error}=await ctx.supabase.from('seller_groups').insert({organization_id:ctx.membership.organization_id,name})
  return error?go(classifyDbFeedback(error)):go('ok:grupo_vendedor_cadastrado')
}

export async function createSeller(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const name=text(f,'name'),category=text(f,'seller_category'),sellerGroup=text(f,'seller_group_id'),commissionGroup=text(f,'commission_group_id')
  const taxId=tax(text(f,'tax_id'))
  const createAccess=text(f,'create_access')==='on'
  const rawEmail=text(f,'email')
  const email=createAccess?normalizeEmail(rawEmail):null
  if(name.length<1||name.length>160||!['pf','pj','sub'].includes(category)||!uuid(sellerGroup)||!uuid(commissionGroup)||taxId===undefined)return go('erro:vendedor_invalido')
  if(createAccess&&!email)return go('erro:vendedor_acesso_email')

  const {data,error}=await ctx.supabase.rpc('create_seller_with_access',{
    p_org:ctx.membership.organization_id,
    p_name:name,
    p_seller_category:category,
    p_tax_id:taxId,
    p_seller_group_id:sellerGroup,
    p_commission_group_id:commissionGroup,
    p_email:email,
  })
  if(error)return go(classifyDbFeedback(error))

  const row=Array.isArray(data)?data[0]:null
  if(!row?.seller_id)return go('erro:inesperado')
  let code:FeedbackCode='ok:vendedor_cadastrado'
  if(createAccess&&email&&row.invitation_id){
    const outcome=await sendInvitationEmail(email)
    code=outcome==='sent'?'ok:vendedor_cadastrado_acesso_enviado':'ok:vendedor_cadastrado_acesso_pendente'
  }
  revalidatePath(PATH)
  return redirect(feedbackUrl(`${PATH}/${row.seller_id}`,code))
}

export async function updateSeller(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const id=text(f,'id'),name=text(f,'name'),category=text(f,'seller_category'),sellerGroup=text(f,'seller_group_id'),commissionGroup=text(f,'commission_group_id')
  const taxId=tax(text(f,'tax_id'))
  if(!uuid(id)||name.length<1||name.length>160||!['pf','pj','sub'].includes(category)||!uuid(sellerGroup)||!uuid(commissionGroup)||taxId===undefined)return go('erro:vendedor_invalido')
  const {error}=await ctx.supabase.from('commercial_sellers').update({
    name,seller_category:category,tax_id:taxId,seller_group_id:sellerGroup,commission_group_id:commissionGroup
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

export async function addSubRule(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const seller=text(f,'seller_id'),share=pct(text(f,'sub_share_pct')),effective=text(f,'effective_from'),component=text(f,'component_key')||'all'
  if(!uuid(seller)||share===null||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(effective)||component.length>80)return go('erro:sub_regra_invalida')
  const latest=await ctx.supabase.from('seller_sub_rule_versions').select('version').eq('seller_id',seller).eq('component_key',component).order('version',{ascending:false}).limit(1).maybeSingle()
  const ins=await ctx.supabase.from('seller_sub_rule_versions').insert({
    organization_id:ctx.membership.organization_id,seller_id:seller,version:(latest.data?.version??0)+1,
    component_key:component,sub_share_pct:share,effective_from:`${effective}T00:00:00Z`,status:'draft'
  }).select('id').single()
  if(ins.error||!ins.data)return go(ins.error?classifyDbFeedback(ins.error):'erro:inesperado')
  const pub=await ctx.supabase.rpc('publish_seller_sub_rule',{p_rule:ins.data.id})
  return pub.error?go(classifyDbFeedback(pub.error)):go('ok:sub_regra_publicada')
}


export async function bindSellerUser(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const sellerId=text(f,'seller_id'),userRaw=text(f,'user_id')
  const userId=userRaw===''?null:userRaw
  if(!uuid(sellerId)||(userId!==null&&!uuid(userId)))return go('erro:vendedor_usuario')
  const {error}=await ctx.supabase.rpc('set_seller_user',{p_seller_id:sellerId,p_user_id:userId})
  return error?go(/forbidden|not_authorized/.test(error.message??'')?'erro:sem_permissao':'erro:vendedor_usuario'):go('ok:vendedor_usuario_vinculado')
}

export async function setSellerSupervision(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const sellerId=text(f,'seller_id'),supervisorId=text(f,'supervisor_user_id'),active=text(f,'active')!=='false'
  if(!uuid(sellerId)||!uuid(supervisorId))return go('erro:supervisao_vendedor')
  const {error}=await ctx.supabase.rpc('set_seller_supervision',{
    p_seller_id:sellerId,p_supervisor_user_id:supervisorId,p_active:active
  })
  return error?go(/forbidden|not_authorized/.test(error.message??'')?'erro:sem_permissao':'erro:supervisao_vendedor'):go('ok:supervisao_vendedor_atualizada')
}


const sellerPath=(id:string)=>`${PATH}/${id}`
const sellerGo=(id:string,code:FeedbackCode):never=>{revalidatePath(sellerPath(id));revalidatePath(`${PATH}/consulta`);return redirect(feedbackUrl(sellerPath(id),code))}
const optionalDate=(v:string)=>/^\d{4}-\d{2}-\d{2}$/.test(v)?v:null

export async function saveSellerProfile(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const sellerId=text(f,'seller_id')
  if(!uuid(sellerId))return go('erro:vendedor_perfil')
  const {error}=await ctx.supabase.rpc('upsert_seller_profile',{
    p_seller_id:sellerId,
    p_legal_name:text(f,'legal_name')||null,
    p_trade_name:text(f,'trade_name')||null,
    p_email:normalizeEmail(text(f,'profile_email')),
    p_phone:text(f,'phone')||null,
    p_whatsapp:text(f,'whatsapp')||null,
    p_birth_or_opening_date:optionalDate(text(f,'birth_or_opening_date')),
    p_identity_or_registration_number:text(f,'identity_or_registration_number')||null,
    p_identity_issuer:text(f,'identity_issuer')||null,
    p_occupation:text(f,'occupation')||null,
    p_notes:text(f,'notes')||null,
  })
  return error?sellerGo(sellerId,'erro:vendedor_perfil'):sellerGo(sellerId,'ok:vendedor_perfil_salvo')
}

export async function saveSellerAddress(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const sellerId=text(f,'seller_id')
  if(!uuid(sellerId))return go('erro:vendedor_endereco')
  const {error}=await ctx.supabase.rpc('replace_seller_address',{
    p_seller_id:sellerId,
    p_postal_code:text(f,'postal_code')||null,
    p_street:text(f,'street')||null,
    p_number:text(f,'number')||null,
    p_complement:text(f,'complement')||null,
    p_neighborhood:text(f,'neighborhood')||null,
    p_city:text(f,'city')||null,
    p_state:text(f,'state')||null,
  })
  return error?sellerGo(sellerId,'erro:vendedor_endereco'):sellerGo(sellerId,'ok:vendedor_endereco_salvo')
}

export async function saveSellerPaymentAccount(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const sellerId=text(f,'seller_id'),bankId=text(f,'bank_id'),accountType=text(f,'account_type'),pixType=text(f,'pix_key_type')
  if(!uuid(sellerId)||(bankId&&!uuid(bankId)))return go('erro:vendedor_pagamento')
  const holderDocument=text(f,'holder_document').replace(/\D/g,'')
  if(!text(f,'holder_name')||![11,14].includes(holderDocument.length))return sellerGo(sellerId,'erro:vendedor_pagamento')
  const {error}=await ctx.supabase.rpc('set_seller_payment_account',{
    p_seller_id:sellerId,
    p_bank_id:bankId||null,
    p_branch:text(f,'branch')||null,
    p_account_number:text(f,'account_number')||null,
    p_account_digit:text(f,'account_digit')||null,
    p_account_type:accountType||null,
    p_holder_name:text(f,'holder_name'),
    p_holder_document:holderDocument,
    p_pix_key_type:pixType||null,
    p_pix_key:text(f,'pix_key')||null,
  })
  return error?sellerGo(sellerId,'erro:vendedor_pagamento'):sellerGo(sellerId,'ok:vendedor_pagamento_salvo')
}

export async function saveSellerCertification(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const sellerId=text(f,'seller_id'),id=text(f,'certification_id'),status=text(f,'status')||'active'
  if(!uuid(sellerId)||(id&&!uuid(id))||!text(f,'certification_name'))return go('erro:vendedor_certificacao')
  const {error}=await ctx.supabase.rpc('upsert_seller_certification',{
    p_id:id||null,
    p_seller_id:sellerId,
    p_name:text(f,'certification_name'),
    p_issuer:text(f,'issuer')||null,
    p_certificate_number:text(f,'certificate_number')||null,
    p_issued_at:optionalDate(text(f,'issued_at')),
    p_expires_at:optionalDate(text(f,'expires_at')),
    p_status:status,
    p_notes:text(f,'certification_notes')||null,
  })
  return error?sellerGo(sellerId,'erro:vendedor_certificacao'):sellerGo(sellerId,'ok:vendedor_certificacao_salva')
}
