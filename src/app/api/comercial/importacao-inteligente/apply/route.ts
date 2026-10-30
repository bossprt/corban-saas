
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { parseBankChoice, parseBaseChoice, parseRepassMap, parseSmartCommercialFile, SMART_IMPORT_ISSUES } from '@/lib/imports/smart-commercial-server'

export const dynamic='force-dynamic'
const BLOCK=500
const PUBLISH_ERRORS:[RegExp,string][]=[
 [/effective_from_out_of_range|effective_from_required/,'Data de início inválida: use uma data a partir de 2000 e até um ano à frente.'],
 [/future_published_version_exists/,'Já existe vigência publicada que começa depois dessa data. Escolha uma data posterior.'],
 [/rate_or_coefficient_required/,'Há tabela sem linhas, taxa ou coeficiente.'],
 [/not_authorized/,'Seu perfil não publica tabelas.'],
]
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)

export async function POST(req:Request){
 try{
  const ctx=await requireAppContext()
  if(!atLeast(ctx.membership.role,'manager'))return Response.json({error:'Sem permissão.'},{status:403})
  const fd=await req.formData()
  const file=fd.get('file')
  if(!(file instanceof File))return Response.json({error:'Envie um arquivo.'},{status:400})
  const origin=String(fd.get('production_origin')??'')
  const provider=String(fd.get('provider_id')??'').trim()
  if(!['own','third_party'].includes(origin))return Response.json({error:'Escolha a origem da produção.'},{status:400})
  if(origin==='third_party'&&!uuid(provider))return Response.json({error:'Escolha a empresa de origem.'},{status:400})
  if(origin==='own'&&provider)return Response.json({error:'Produção própria não usa empresa de origem.'},{status:400})
  // Optional: publish the imported drafts right away from this day (YYYY-MM-DD). Empty = they stay drafts, as before.
  const publishFrom=String(fd.get('publish_from')??'').trim()
  if(publishFrom&&!/^\d{4}-\d{2}-\d{2}$/.test(publishFrom))return Response.json({error:'Data de início inválida.'},{status:400})

  // Every "Repasse N" must have an answer (a group or "Não usar"): nothing is imported by guess.
  const parsed=await parseSmartCommercialFile(ctx,file,parseRepassMap(fd.get('repass_map')),parseBaseChoice(fd.get('calculation_base')),parseBankChoice(fd.get('bank_id')))
  const hard=parsed.issues
  if(hard.length)return Response.json({error:'O arquivo ainda possui erros.',issues:hard.map(x=>({...x,message:SMART_IMPORT_ISSUES[x.code]??x.code}))},{status:400})
  if(!parsed.rows.length)return Response.json({error:'Nenhuma linha válida para importar.'},{status:400})

  const payload=parsed.rows.map(r=>({
    bank_name:r.bank_name,agreement_name:r.agreement_name,table_name:r.table_name,external_table_code:r.external_table_code,
    contract_type_id:r.contract_type_id,contract_type_name:r.contract_type_name,term:r.term,
    ...(r.amount_min===undefined?{}:{amount_min:r.amount_min,amount_max:r.amount_max}),
    coefficient:r.coefficient,rate:r.rate,effective_from:r.effective_from,effective_until:r.effective_until,
    factor_mode:r.factor_mode,factor_value:r.factor_value,factor_date:r.factor_date,components:r.components,group_values:r.group_values,...(r.tax_pct===undefined?{}:{tax_pct:r.tax_pct}),
    ...(r.production_origin===undefined?{}:{production_origin:r.production_origin,provider_id:r.provider_id}),
    ...(r.formalization===undefined?{}:{formalization:r.formalization}),
  }))
  // The database takes up to 1.000 rows per call: big files (a whole bank, or every table) go in blocks. Each block is
  // all or nothing; a later block that fails leaves only drafts, and importing the file again reuses those drafts.
  const total:Record<string,number>={}
  const versionIds=new Set<string>()
  for(let i=0;i<payload.length;i+=BLOCK){
   const {data,error}=await ctx.supabase.rpc('import_smart_commercial_rows',{
    p_organization:ctx.membership.organization_id,
    p_production_origin:origin,
    p_provider:origin==='third_party'?provider:null,
    p_policy_version:null,
    p_rows:payload.slice(i,i+BLOCK)
   })
   if(error)return Response.json({error:`${i>0?`As primeiras ${i} linhas já entraram como rascunho. `:''}${error.message||'Importação recusada pelo banco de dados.'}`},{status:400})
   for(const [k,v] of Object.entries((data??{}) as Record<string,unknown>)){
    if(Array.isArray(v))v.forEach(id=>versionIds.add(String(id)))
    else total[k]=(total[k]??0)+Number(v)
   }
  }
  if(!publishFrom||!versionIds.size)return Response.json({ok:true,result:total,summary:parsed.summary})
  // All drafts of this file in one call: either all are published or none is (they stay drafts and the reason is shown).
  const {data:published,error:pubError}=await ctx.supabase.rpc('publish_product_table_versions',{p_version_ids:[...versionIds],p_effective_from:publishFrom})
  const publishError=pubError?PUBLISH_ERRORS.find(([re])=>re.test(pubError.message??''))?.[1]??'Não foi possível publicar.':null
  return Response.json({ok:true,result:total,summary:parsed.summary,published:pubError?0:Number(published??0),publishFrom,publishError})
 }catch{
  return Response.json({error:'Não foi possível concluir a importação.'},{status:500})
 }
}
