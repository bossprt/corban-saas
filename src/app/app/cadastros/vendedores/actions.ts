'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, FEEDBACK, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { createMemberLogin } from '@/lib/team.server'
import { PASSWORD_MAX, PASSWORD_MIN } from '@/lib/team'
import { sellerData } from './sellerData'
import { formatTaxId } from '@/lib/sellers'
import { searchTerm } from '@/lib/search'

const PATH='/app/cadastros/vendedores'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
// Actions triggered from a seller's page go back to that page; everything else to the list.
const pageOf=(f:FormData)=>{const id=text(f,'id')||text(f,'seller_id');return uuid(id)?`${PATH}/${id}`:PATH}
const go=(code:FeedbackCode,path=PATH):never=>{revalidatePath(PATH);return redirect(feedbackUrl(path,code))}
const manager=async()=>{const ctx=await requireAppContext();return atLeast(ctx.membership.role,'manager')?ctx:null}

const SELLER_ERRORS:[RegExp,FeedbackCode][]=[
  [/seller_name_required/,'erro:vendedor_nome'],
  [/seller_tax_id_invalid/,'erro:vendedor_documento'],
  [/seller_tax_id_exists/,'erro:vendedor_documento_repetido'],
  [/seller_internal_no_tax_id/,'erro:vendedor_documento'],
  [/seller_mobile_required|seller_phone_invalid/,'erro:vendedor_celular'],
  [/seller_email_required/,'erro:vendedor_email'],
  [/seller_group_invalid|seller_category_invalid|seller_branch_invalid/,'erro:vendedor_invalido'],
  [/seller_pix_key_invalid/,'erro:vendedor_pix'],
  [/seller_holder_invalid/,'erro:vendedor_favorecido'],
  [/seller_account_invalid|seller_account_not_found/,'erro:vendedor_conta'],
  [/seller_contact_invalid/,'erro:vendedor_contato'],
  [/active_matrix_required/,'erro:sem_matriz'],
]

// Register or change a seller: one database call (save_seller) writes identity, profile, accounts and contacts.
// A refusal comes back as a message and the form keeps what was typed; only success leaves the page.
export async function saveSeller(f:FormData):Promise<{error:string}>{
  const ctx=await manager()
  const sellerId=text(f,'seller_id')
  const back=(code:FeedbackCode)=>({error:FEEDBACK[code]})
  if(!ctx)return back('erro:sem_permissao')
  if(sellerId&&!uuid(sellerId))return back('erro:requisicao_invalida')
  const data=sellerData(f)

  // A request from the registration link is approved by saving it: save_seller and the closing of the request run together.
  const signupId=text(f,'signup_id')
  if(signupId&&(sellerId||!uuid(signupId)))return back('erro:requisicao_invalida')
  const {data:id,error}=signupId
    ?await ctx.supabase.rpc('seller_signup_approve',{p_request:signupId,p_data:data})
    :await ctx.supabase.rpc('save_seller',{p_org:ctx.membership.organization_id,p_seller:sellerId||null,p_data:data})
  if(error){
    const m=error.message??''
    if(/signup_already_decided/.test(m))return back('erro:cadastro_link_decidido')
    return back(SELLER_ERRORS.find(([re])=>re.test(m))?.[1]??classifyDbFeedback(error))
  }
  return go(sellerId?'ok:vendedor_atualizado':'ok:vendedor_cadastrado',`${PATH}/${id as string}`)
}

export async function setSellerActive(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao',pageOf(f))
  const id=text(f,'id'),active=text(f,'active')==='true'
  if(!uuid(id))return go('erro:vendedor_invalido')
  const {error}=await ctx.supabase.from('commercial_sellers').update({is_active:active}).eq('id',id)
  return error?go(classifyDbFeedback(error),pageOf(f)):go('ok:vendedor_atualizado',pageOf(f))
}

// Portal access (F7), created by the manager with e-mail and password (owner decision 29/09/2026): the database checks the
// e-mail and creates the invitation that carries the 'corretor' role and binds the seller; the server creates the login and
// accepts it at once. No e-mail is sent. The password is never logged.
export async function createSellerPortalAccess(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao',pageOf(f))
  const id=text(f,'id'),email=text(f,'email').toLowerCase()
  if(!uuid(id)||!/^[^@\s]+@[^@\s]+$/.test(email))return go('erro:requisicao_invalida',pageOf(f))
  const password=text(f,'password')
  if(password.length<PASSWORD_MIN||password.length>PASSWORD_MAX||password!==text(f,'password_confirm'))return go('erro:portal_senha',pageOf(f))
  const mustChange=f.get('must_change')==='on'
  const {data:existing,error:checkError}=await ctx.supabase.rpc('check_login_email',{p_org:ctx.membership.organization_id,p_email:email})
  if(checkError){
    const m=checkError.message??''
    if(/email_has_other_access/.test(m))return go('erro:portal_email_outra_empresa',pageOf(f))
    if(/already_member/.test(m))return go('erro:portal_acesso_existente',pageOf(f))
    return go(classifyDbFeedback(checkError),pageOf(f))
  }
  const {error}=await ctx.supabase.rpc('invite_seller_to_portal',{p_seller:id,p_email:email})
  // A previous try that stopped at the password left the invitation pending (06/10/2026): when it is this seller's,
  // go on and create the login, which accepts it; otherwise say the e-mail is waiting for another access.
  if(error&&/invitation_already_pending/.test(error.message??'')){
    const {data:pending}=await ctx.supabase.from('organization_invitations').select('seller_id').eq('status','pending').ilike('email',email).limit(1).maybeSingle()
    if(pending?.seller_id!==id)return go('erro:portal_convite_pendente',pageOf(f))
  }else if(error){
    const m=error.message??''
    if(/portal_role_missing/.test(m))return go('erro:portal_papel',pageOf(f))
    if(/seller_already_has_access/.test(m))return go('erro:portal_acesso_existente',pageOf(f))
    return go(classifyDbFeedback(error),pageOf(f))
  }
  const outcome=await createMemberLogin(email,password,typeof existing==='string'?existing:null,mustChange)
  if(outcome==='created')return go('ok:portal_acesso',pageOf(f))
  return go(outcome==='failed'?'erro:portal_acesso_falhou':'erro:portal_senha_fraca',pageOf(f))
}

// Link the seller record to a team member who already has a login, of any role (owner request 06/10/2026): a manager
// who also sells stays a manager; empty user_id undoes the link. The database checks company, role and that the person
// is not linked to another seller.
export async function linkSellerUser(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao',pageOf(f))
  const id=text(f,'id'),userId=text(f,'user_id')
  if(!uuid(id)||(userId&&!uuid(userId)))return go('erro:requisicao_invalida',pageOf(f))
  const {error}=await ctx.supabase.rpc('set_seller_user',{p_seller_id:id,p_user_id:userId||null})
  if(error){
    const m=error.message??''
    if(/user_already_linked/.test(m))return go('erro:vendedor_usuario_ja_ligado',pageOf(f))
    if(/active_membership_required/.test(m))return go('erro:vendedor_usuario_invalido',pageOf(f))
    return go(classifyDbFeedback(error),pageOf(f))
  }
  return go(userId?'ok:vendedor_ligado':'ok:vendedor_desligado',pageOf(f))
}

// Registration links (05/11/2026): one per seller group; "new" also replaces a link that leaked (the old one stops).
const LINKS=`${PATH}/links`
export async function newSignupLink(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao',LINKS)
  const group=text(f,'group_id')
  if(!uuid(group))return go('erro:requisicao_invalida',LINKS)
  const {error}=await ctx.supabase.rpc('seller_signup_link_new',{p_org:ctx.membership.organization_id,p_group:group})
  if(error)return go(/seller_group_invalid/.test(error.message??'')?'erro:vendedor_invalido':classifyDbFeedback(error),LINKS)
  revalidatePath(LINKS)
  return go('ok:cadastro_link_criado',LINKS)
}

export async function setSignupLinkActive(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao',LINKS)
  const id=text(f,'link_id'),active=text(f,'active')==='true'
  if(!uuid(id))return go('erro:requisicao_invalida',LINKS)
  const {error}=await ctx.supabase.rpc('seller_signup_link_set_active',{p_link:id,p_active:active})
  revalidatePath(LINKS)
  return go(error?classifyDbFeedback(error):active?'ok:cadastro_link_ligado':'ok:cadastro_link_desligado',LINKS)
}

// Refusing one or several requests (after a confirmation on the screen) erases what was sent; name, document, who
// refused and when stay as a record, listed under "Recusados". Requests already decided are skipped by the database.
export async function rejectSignup(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao')
  const ids=[...new Set(f.getAll('signup_id').map(v=>String(v).trim()).filter(Boolean))]
  if(!ids.length)return go('erro:cadastro_link_nenhum')
  if(ids.length>200||!ids.every(uuid))return go('erro:requisicao_invalida')
  const {data,error}=await ctx.supabase.rpc('seller_signup_reject_many',{p_requests:ids})
  if(error)return go(classifyDbFeedback(error))
  if(!data)return go('erro:cadastro_link_decidido')
  return go(ids.length>1?'ok:cadastro_link_recusados':'ok:cadastro_link_recusado')
}

// Seller search (audit 06/11/2026). A CPF/CNPJ never goes in the address bar (RULES 2.7): it is looked up here and the
// seller page opens directly. Names and codes become the list filter (?q=).
export async function searchSellers(f:FormData){
  const ctx=await requireAppContext()
  if(!atLeast(ctx.membership.role,'supervisor'))return go('erro:sem_permissao')
  const term=text(f,'q').slice(0,80)
  const status=['ativos','inativos'].includes(text(f,'situacao'))?text(f,'situacao'):''
  const digits=term.replace(/\D/g,'')
  if((digits.length===11||digits.length===14)&&!/[a-z]/i.test(term)){
    const { data }=await ctx.supabase.from('commercial_sellers').select('id').in('tax_id',[digits,formatTaxId(digits)]).limit(1)
    const id=(data??[])[0]?.id
    return id?redirect(`${PATH}/${id}`):redirect(feedbackUrl(PATH,'erro:vendedor_cpf_nao_encontrado'))
  }
  const q=searchTerm(term)
  const qs=new URLSearchParams(Object.entries({q:q??'',situacao:status}).filter(([,v])=>v)).toString()
  return redirect(`${PATH}${qs?`?${qs}`:''}`)
}
