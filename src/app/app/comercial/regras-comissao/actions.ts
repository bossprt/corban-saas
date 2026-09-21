'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const PATH='/app/comercial/regras-comissao'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const go=(c:FeedbackCode):never=>{revalidatePath(PATH);return redirect(feedbackUrl(PATH,c))}
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
const dec=(v:string)=>{const n=Number(v.replace(',','.'));return Number.isFinite(n)&&n>=0?n:null}
const manager=async()=>{const ctx=await requireAppContext();return atLeast(ctx.membership.role,'manager')?ctx:null}

export async function saveComponentPolicy(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const policyId=text(f,'policy_id'),name=text(f,'name'),bank=text(f,'bank_id'),agreement=text(f,'agreement_id'),table=text(f,'table_id'),effective=text(f,'effective_from')
 const discount=dec(text(f,'discount')||'0')
 if((policyId&&!uuid(policyId))||(!policyId&&(name.length<1||name.length>100))||(bank&&!uuid(bank))||(agreement&&!uuid(agreement))||(table&&!uuid(table))||discount===null||discount>100||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(effective))return go('erro:regra_comissao_invalida')
 const [groups,components]=await Promise.all([
  ctx.supabase.from('commission_groups').select('id').eq('is_active',true),
  ctx.supabase.from('commission_component_types').select('id').eq('is_active',true)
 ])
 const items:{group_id:string;component_type_id:string;mode:string;share_pct:number|null;direct_value_kind:string|null;direct_value:number|null}[]=[]
 for(const g of groups.data??[])for(const c of components.data??[]){
  const prefix=`${g.id}_${c.id}`, mode=text(f,`m_${prefix}`)||'exclude'
  if(mode==='exclude'){items.push({group_id:g.id,component_type_id:c.id,mode,share_pct:null,direct_value_kind:null,direct_value:null});continue}
  const value=dec(text(f,`v_${prefix}`))
  if(value===null)return go('erro:regra_comissao_invalida')
  if(mode==='share_of_received'){
    if(value>100)return go('erro:regra_comissao_invalida')
    items.push({group_id:g.id,component_type_id:c.id,mode,share_pct:value,direct_value_kind:null,direct_value:null})
  }else if(mode==='direct'){
    const kind=text(f,`k_${prefix}`)
    if(!['percentage','fixed_brl'].includes(kind))return go('erro:regra_comissao_invalida')
    items.push({group_id:g.id,component_type_id:c.id,mode,share_pct:null,direct_value_kind:kind,direct_value:value})
  }else return go('erro:regra_comissao_invalida')
 }
 const {error}=await ctx.supabase.rpc('save_component_payout_policy',{
  p_organization:ctx.membership.organization_id,p_name:policyId?null:name,p_bank:bank||null,p_agreement:agreement||null,p_table:table||null,
  p_discount:String(discount),p_effective_from:`${effective}T00:00:00Z`,p_items:items,p_policy:policyId||null
 })
 return error?go(classifyDbFeedback(error)):go('ok:regra_comissao_salva')
}
