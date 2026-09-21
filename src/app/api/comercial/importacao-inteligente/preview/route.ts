
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { parseSmartCommercialFile, SMART_IMPORT_ISSUES } from '@/lib/imports/smart-commercial-server'
import { componentEconomics } from '@/lib/commission/component-economics'

export const dynamic='force-dynamic'

export async function POST(req:Request){
 try{
  const ctx=await requireAppContext()
  if(!atLeast(ctx.membership.role,'manager'))return Response.json({error:'Sem permissão.'},{status:403})
  const fd=await req.formData()
  const file=fd.get('file')
  if(!(file instanceof File))return Response.json({error:'Envie um arquivo.'},{status:400})
  const parsed=await parseSmartCommercialFile(ctx,file)
  const policyId=String(fd.get('policy_version_id')??'').trim()
  let economics:any[]=[]
  if(policyId){
   const [pv,items,groups,components]=await Promise.all([
    ctx.supabase.from('component_payout_policy_versions').select('id,discount_pct').eq('id',policyId).maybeSingle(),
    ctx.supabase.from('component_payout_policy_items').select('group_id,component_type_id,mode,share_pct,direct_value_kind,direct_value').eq('version_id',policyId),
    ctx.supabase.from('commission_groups').select('id,name'),
    ctx.supabase.from('commission_component_types').select('id,name,tech_key'),
   ])
   if(!pv.data)return Response.json({error:'Regra de comissão não encontrada.'},{status:400})
   const gn=new Map((groups.data??[]).map(x=>[x.id,x.name]))
   const cn=new Map((components.data??[]).map(x=>[x.id,x.name]))
   const seen=new Set<string>()
   for(const row of parsed.rows.slice(0,20)){
    for(const c of row.components){
     for(const it of (items.data??[]).filter(x=>x.component_type_id===c.component_type_id)){
      const key=row.table_name+'|'+row.contract_type_id+'|'+String(row.term)+'|'+c.component_type_id+'|'+it.group_id
      if(seen.has(key)||economics.length>=30)continue
      seen.add(key)
      const calc=componentEconomics({
       receivedValue:String(c.received_value),receivedKind:c.value_kind,discountPct:String(pv.data.discount_pct),
       mode:it.mode,sharePct:it.share_pct==null?null:String(it.share_pct),
       directValueKind:it.direct_value_kind,directValue:it.direct_value==null?null:String(it.direct_value)
      })
      economics.push({table:row.table_name,contract:row.contract_type_name,term:row.term,component:cn.get(c.component_type_id)??'Componente',group:gn.get(it.group_id)??'Grupo',kind:c.value_kind,...calc})
     }
    }
   }
  }
  const hard=parsed.issues.filter(x=>x.code!=='generic_repass_requires_mapping')
  return Response.json({
   ok:hard.length===0,
   fileName:file.name,
   summary:parsed.summary,
   issues:parsed.issues.map(x=>({...x,message:SMART_IMPORT_ISSUES[x.code]??x.code})),
   economics,
   sample:parsed.rows.slice(0,8).map(r=>({
    bank:r.bank_name,agreement:r.agreement_name,table:r.table_name,contract:r.contract_type_name,
    term:r.term,rate:r.rate,factor:r.factor_value,components:r.components.length
   })),
  })
 }catch(e){
  const m=e instanceof Error?e.message:'unexpected'
  return Response.json({error:m==='unsupported_file'?'Use CSV ou XLSX.':m==='invalid_file'?'Arquivo vazio ou maior que 2 MB.':'Não foi possível ler o arquivo.'},{status:400})
 }
}
