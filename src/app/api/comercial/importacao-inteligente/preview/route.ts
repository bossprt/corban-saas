
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { contractTypeMapFromForm, genericRepassMapFromForm, headerMapFromForm, parseSmartCommercialFile, SMART_IMPORT_ISSUES, suggestSmartPolicyScope, validateSmartPolicyScope } from '@/lib/imports/smart-commercial-server'
import { safeFileName } from '@/lib/imports/file-guards'
import { componentEconomics, decimalEqual } from '@/lib/commission/component-economics'

export const dynamic='force-dynamic'

export async function POST(req:Request){
 try{
  const ctx=await requireAppContext()
  if(!atLeast(ctx.membership.role,'manager'))return Response.json({error:'Sem permissão.'},{status:403})
  const fd=await req.formData()
  const file=fd.get('file')
  if(!(file instanceof File))return Response.json({error:'Envie um arquivo.'},{status:400})
  const headerMap=headerMapFromForm(fd)
  const contractTypeMap=contractTypeMapFromForm(fd)
  const genericRepassMap=genericRepassMapFromForm(fd)
  const parsed=await parseSmartCommercialFile(ctx,file,headerMap,contractTypeMap,genericRepassMap)
  const requestedPolicyId=String(fd.get('policy_version_id')??'').trim()
  const suggestion=await suggestSmartPolicyScope(ctx,ctx.membership.organization_id,parsed.rows)
  const policyId=requestedPolicyId||suggestion.suggested?.versionId||''
  type Econ={table:string;contract:string;term:number;component:string;group:string;groupId:string;componentTypeId:string;mode:'share_of_received'|'direct'|'exclude';sharePct:string|null;receivedKind:'percentage'|'fixed_brl';gross:string;net:string;payout:string;retained:string|null;payoutKind:'percentage'|'fixed_brl'|null;compatible:boolean}
  const economics:Econ[]=[]
  if(policyId){
    const scope=await validateSmartPolicyScope(ctx,ctx.membership.organization_id,policyId,parsed.rows)
    if(!scope.ok)return Response.json({error:scope.error},{status:400})
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
          economics.push({table:row.table_name,contract:row.contract_type_name,term:row.term,component:componentName.get(component.component_type_id)??'Componente',group:groupName.get(item.group_id)??'Grupo',groupId:item.group_id,componentTypeId:component.component_type_id,mode:item.mode,sharePct:item.share_pct==null?null:String(item.share_pct),receivedKind:component.value_kind,...calc})
        }
      }
    }
  }

  const repassComparisons=parsed.rows.flatMap(row=>row.source_repasses.filter(r=>r.source_slot&&r.rule_hint!=='unknown').map(r=>{
    const internal=economics.find(e=>e.table===row.table_name&&e.contract===row.contract_type_name&&e.term===row.term&&e.groupId===r.group_id&&e.componentTypeId===r.component_type_id)
    if(!internal)return {table:row.table_name,contract:row.contract_type_name,term:row.term,groupId:r.group_id,componentTypeId:r.component_type_id,slot:r.source_slot,external:r.raw_value,externalKind:r.value_kind_hint,internal:null as string|null,status:'no_internal_rule' as const}
    if(r.rule_hint==='direct'){
      if(!r.value_kind_hint||internal.payoutKind!==r.value_kind_hint)return {table:row.table_name,contract:row.contract_type_name,term:row.term,groupId:r.group_id,componentTypeId:r.component_type_id,slot:r.source_slot,external:r.raw_value,externalKind:r.value_kind_hint,internal:internal.payout,status:'incompatible_unit' as const}
      return {table:row.table_name,contract:row.contract_type_name,term:row.term,groupId:r.group_id,componentTypeId:r.component_type_id,slot:r.source_slot,external:r.raw_value,externalKind:r.value_kind_hint,internal:internal.payout,status:decimalEqual(r.raw_value,internal.payout)?'match' as const:'different' as const}
    }
    if(internal.mode!=='share_of_received'||internal.sharePct==null)return {table:row.table_name,contract:row.contract_type_name,term:row.term,groupId:r.group_id,componentTypeId:r.component_type_id,slot:r.source_slot,external:r.raw_value,externalKind:'percentage' as const,internal:internal.sharePct,status:'incompatible_semantics' as const}
    return {table:row.table_name,contract:row.contract_type_name,term:row.term,groupId:r.group_id,componentTypeId:r.component_type_id,slot:r.source_slot,external:r.raw_value,externalKind:'percentage' as const,internal:internal.sharePct,status:decimalEqual(r.raw_value,internal.sharePct)?'match' as const:'different' as const}
  })).slice(0,60)

  const hard=parsed.issues.filter(x=>x.code!=='generic_repass_requires_mapping')
  return Response.json({
   ok:hard.length===0,
   fileName:safeFileName(file.name),
   format:parsed.format,
   headers:parsed.headers,
   headerMapApplied:parsed.headerMapApplied,
   contractTypes:parsed.availableContractTypes,
   groups:parsed.availableGroups,
   needsReview:parsed.issues.some(x=>x.code.startsWith('pdf_')),
   summary:parsed.summary,
   economics,
   suggestedPolicy:suggestion.suggested,
   ambiguousPolicies:suggestion.ambiguous,
   policyUsedForPreview:policyId||null,
   issues:parsed.issues.map(x=>({...x,message:SMART_IMPORT_ISSUES[x.code]??x.code})),
   repasses:parsed.rows.flatMap(r=>r.source_repasses.map(x=>({table:r.table_name,contract:r.contract_type_name,term:r.term,...x}))).slice(0,40),
   repassComparisons,
   sample:parsed.rows.slice(0,8).map(r=>({
    bank:r.bank_name,agreement:r.agreement_name,table:r.table_name,contract:r.contract_type_name,
    term:r.term,rate:r.rate,factor:r.factor_value,components:r.components.length
   })),
  })
 }catch(e){
  const m=e instanceof Error?e.message:'unexpected'
  return Response.json({error:m==='invalid_file'?'Arquivo vazio ou maior que 5 MB.':(m==='invalid_header_map'||m==='invalid_contract_type_map'||m==='invalid_generic_repass_map')?'Mapeamento manual inválido.':'Não foi possível ler o arquivo.'},{status:400})
 }
}
