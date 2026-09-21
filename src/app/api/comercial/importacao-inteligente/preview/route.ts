
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { headerMapFromForm, parseSmartCommercialFile, SMART_IMPORT_ISSUES } from '@/lib/imports/smart-commercial-server'
import { safeFileName } from '@/lib/imports/file-guards'
import { componentEconomics } from '@/lib/commission/component-economics'

export const dynamic='force-dynamic'

export async function POST(req:Request){
 try{
  const ctx=await requireAppContext()
  if(!atLeast(ctx.membership.role,'manager'))return Response.json({error:'Sem permissão.'},{status:403})
  const fd=await req.formData()
  const file=fd.get('file')
  if(!(file instanceof File))return Response.json({error:'Envie um arquivo.'},{status:400})
  const headerMap=headerMapFromForm(fd)
  const parsed=await parseSmartCommercialFile(ctx,file,headerMap)
  const policyId=String(fd.get('policy_version_id')??'').trim()
  type Econ={table:string;contract:string;term:number;component:string;group:string;receivedKind:'percentage'|'fixed_brl';gross:string;net:string;payout:string;retained:string|null;payoutKind:'percentage'|'fixed_brl'|null;compatible:boolean}
  const economics:Econ[]=[]
  if(policyId){
    const [versionQ,itemsQ,groupsQ,componentsQ]=await Promise.all([
      ctx.supabase.from('component_payout_policy_versions').select('id,organization_id,discount_pct').eq('id',policyId).eq('organization_id',ctx.membership.organization_id).maybeSingle(),
      ctx.supabase.from('component_payout_policy_items').select('group_id,component_type_id,mode,share_pct,direct_value_kind,direct_value').eq('version_id',policyId),
      ctx.supabase.from('commission_groups').select('id,name'),
      ctx.supabase.from('commission_component_types').select('id,name'),
    ])
    const version=versionQ.data as {id:string;discount_pct:string|number}|null
    if(!version)return Response.json({error:'Regra de comissão não encontrada para esta empresa.'},{status:400})
    const groupName=new Map(((groupsQ.data??[]) as {id:string;name:string}[]).map(x=>[x.id,x.name]))
    const componentName=new Map(((componentsQ.data??[]) as {id:string;name:string}[]).map(x=>[x.id,x.name]))
    const items=(itemsQ.data??[]) as {group_id:string;component_type_id:string;mode:'share_of_received'|'direct'|'exclude';share_pct:string|number|null;direct_value_kind:'percentage'|'fixed_brl'|null;direct_value:string|number|null}[]
    const seen=new Set<string>()
    for(const row of parsed.rows.slice(0,25)){
      for(const component of row.components){
        for(const item of items.filter(x=>x.component_type_id===component.component_type_id)){
          const key=[row.table_name,row.contract_type_id,row.term,component.component_type_id,item.group_id].join('|')
          if(seen.has(key)||economics.length>=40)continue
          seen.add(key)
          const calc=componentEconomics({
            receivedValue:String(component.received_value),receivedKind:component.value_kind,
            discountPct:String(version.discount_pct??0),mode:item.mode,
            sharePct:item.share_pct==null?null:String(item.share_pct),
            directValueKind:item.direct_value_kind,
            directValue:item.direct_value==null?null:String(item.direct_value),
          })
          economics.push({table:row.table_name,contract:row.contract_type_name,term:row.term,component:componentName.get(component.component_type_id)??'Componente',group:groupName.get(item.group_id)??'Grupo',receivedKind:component.value_kind,...calc})
        }
      }
    }
  }
  const hard=parsed.issues.filter(x=>x.code!=='generic_repass_requires_mapping')
  return Response.json({
   ok:hard.length===0,
   fileName:safeFileName(file.name),
   format:parsed.format,
   headers:parsed.headers,
   headerMapApplied:parsed.headerMapApplied,
   needsReview:parsed.issues.some(x=>x.code.startsWith('pdf_')),
   summary:parsed.summary,
   economics,
   issues:parsed.issues.map(x=>({...x,message:SMART_IMPORT_ISSUES[x.code]??x.code})),
   sample:parsed.rows.slice(0,8).map(r=>({
    bank:r.bank_name,agreement:r.agreement_name,table:r.table_name,contract:r.contract_type_name,
    term:r.term,rate:r.rate,factor:r.factor_value,components:r.components.length
   })),
  })
 }catch(e){
  const m=e instanceof Error?e.message:'unexpected'
  return Response.json({error:m==='invalid_file'?'Arquivo vazio ou maior que 5 MB.':m==='invalid_header_map'?'Mapeamento manual inválido.':'Não foi possível ler o arquivo.'},{status:400})
 }
}
