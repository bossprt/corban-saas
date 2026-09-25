'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { sendInvitationEmail } from '@/lib/team.server'

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
  [/seller_mobile_required|seller_phone_invalid/,'erro:vendedor_celular'],
  [/seller_email_required/,'erro:vendedor_email'],
  [/seller_group_invalid|seller_category_invalid|seller_branch_invalid/,'erro:vendedor_invalido'],
  [/seller_pix_key_invalid/,'erro:vendedor_pix'],
  [/seller_holder_invalid/,'erro:vendedor_favorecido'],
  [/seller_account_invalid|seller_account_not_found/,'erro:vendedor_conta'],
  [/seller_contact_invalid/,'erro:vendedor_contato'],
]

// The rows of a repeated block, read in order: every row posts the same names.
function rows(f:FormData,names:string[]):Record<string,string>[]{
  const cols=names.map(n=>f.getAll(n).map(v=>String(v).trim()))
  const n=Math.max(0,...cols.map(c=>c.length))
  return Array.from({length:n},(_,i)=>Object.fromEntries(names.map((k,j)=>[k,cols[j][i]??''])))
}

// Register or change a seller: one database call (save_seller) writes identity, profile, accounts and contacts.
export async function saveSeller(f:FormData){
  const ctx=await manager()
  const sellerId=text(f,'seller_id')
  const back=(code:FeedbackCode)=>go(code,sellerId?`${PATH}/${sellerId}`:`${PATH}/novo`)
  if(!ctx)return back('erro:sem_permissao')
  if(sellerId&&!uuid(sellerId))return back('erro:requisicao_invalida')
  const mobile=text(f,'mobile')
  const profile:Record<string,string>={
    trade_name:text(f,'trade_name'),birth_date:text(f,'birth_date'),rg:text(f,'rg'),rg_issuer:text(f,'rg_issuer'),rg_issued_on:text(f,'rg_issued_on'),
    mother_name:text(f,'mother_name'),father_name:text(f,'father_name'),mobile,
    whatsapp:f.get('whatsapp_same')==='on'?mobile:text(f,'whatsapp'),other_phones:text(f,'other_phones'),email:text(f,'email'),
  }
  for(const p of ['','business_'])for(const k of ['zip','street','number','complement','district','city','state'])profile[`${p}${k}`]=text(f,`${p}${k}`)

  const data:Record<string,unknown>={
    name:text(f,'name'),tax_id:text(f,'tax_id'),category:text(f,'seller_category'),group_id:text(f,'commission_group_id'),
    branch_id:text(f,'branch_id'),profile,
    contacts:rows(f,['contact_name','contact_cpf','contact_role','contact_mobile','contact_email'])
      .filter(c=>Object.values(c).some(Boolean))
      .map(c=>({name:c.contact_name,cpf:c.contact_cpf,role:c.contact_role,mobile:c.contact_mobile,email:c.contact_email})),
  }
  // Bank accounts travel only when the form carried them (who cannot see bank data never overwrites it).
  if(f.get('accounts_included')==='1'){
    const primary=Number(text(f,'primary_account')||'0')
    const accountRows=rows(f,['account_id','remove_account','has_payee','transfer_method','pix_key_type','pix_key','account_type','bank_code','bank_name','branch','account_number','account_digit','holder_name','holder_document','account_note'])
    data.accounts=accountRows.map((a,i)=>({a,i})).filter(({a})=>a.account_id||a.pix_key||a.bank_code||a.account_number||a.branch).map(({a,i})=>{
      const payee=a.has_payee==='1'
      return {
        id:a.account_id||null,remove:a.remove_account==='1',primary:i===primary,transfer_method:a.transfer_method,
        pix_key_type:a.pix_key_type,pix_key:a.pix_key,account_type:a.account_type,bank_code:a.bank_code,bank_name:a.bank_name,branch:a.branch,
        account_number:a.account_number,account_digit:a.account_digit,
        holder_name:payee?a.holder_name:'',holder_document:payee?a.holder_document:'',note:a.account_note,
      }
    })
  }

  const {data:id,error}=await ctx.supabase.rpc('save_seller',{p_org:ctx.membership.organization_id,p_seller:sellerId||null,p_data:data})
  if(error){
    const m=error.message??''
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

// Portal access (F7): the database creates an invitation that carries the 'corretor' role and binds the seller on
// acceptance; the e-mail goes out through Supabase Auth.
export async function inviteSellerToPortal(f:FormData){
  const ctx=await manager(); if(!ctx)return go('erro:sem_permissao',pageOf(f))
  const id=text(f,'id'),email=text(f,'email').toLowerCase()
  if(!uuid(id)||!/^[^@\s]+@[^@\s]+$/.test(email))return go('erro:requisicao_invalida',pageOf(f))
  const {error}=await ctx.supabase.rpc('invite_seller_to_portal',{p_seller:id,p_email:email})
  if(error){
    const m=error.message??''
    if(/portal_role_missing/.test(m))return go('erro:portal_papel',pageOf(f))
    if(/seller_already_has_access/.test(m))return go('erro:portal_acesso_existente',pageOf(f))
    return go(classifyDbFeedback(error),pageOf(f))
  }
  const outcome=await sendInvitationEmail(email)
  return go(outcome==='failed'?'erro:portal_convite_email':'ok:portal_convite',pageOf(f))
}
