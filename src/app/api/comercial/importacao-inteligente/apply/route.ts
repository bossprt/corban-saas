
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { parseSmartCommercialFile, SMART_IMPORT_ISSUES } from '@/lib/imports/smart-commercial-server'

export const dynamic='force-dynamic'
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
  const policy=String(fd.get('policy_version_id')??'').trim()
  const ignoreLegacy=String(fd.get('ignore_legacy_repasses')??'')==='true'
  if(!['own','third_party'].includes(origin))return Response.json({error:'Escolha a origem da produção.'},{status:400})
  if(origin==='third_party'&&!uuid(provider))return Response.json({error:'Escolha a empresa de origem.'},{status:400})
  if(origin==='own'&&provider)return Response.json({error:'Produção própria não usa empresa de origem.'},{status:400})
  if(policy&&!uuid(policy))return Response.json({error:'Regra de comissão inválida.'},{status:400})

  const parsed=await parseSmartCommercialFile(ctx,file)
  const generic=parsed.issues.some(x=>x.code==='generic_repass_requires_mapping')
  const hard=parsed.issues.filter(x=>x.code!=='generic_repass_requires_mapping')
  if(hard.length)return Response.json({error:'O arquivo ainda possui erros.',issues:hard.map(x=>({...x,message:SMART_IMPORT_ISSUES[x.code]??x.code}))},{status:400})
  if(generic&&!ignoreLegacy)return Response.json({error:'Confirme que os campos Repasse 1/2/3 serão ignorados e que a regra interna do Corban será usada.'},{status:400})
  if(!parsed.rows.length)return Response.json({error:'Nenhuma linha válida para importar.'},{status:400})

  const payload=parsed.rows.map(r=>({
    bank_name:r.bank_name,agreement_name:r.agreement_name,table_name:r.table_name,external_table_code:r.external_table_code,
    contract_type_id:r.contract_type_id,contract_type_name:r.contract_type_name,term:r.term,
    coefficient:r.coefficient,rate:r.rate,effective_from:r.effective_from,effective_until:r.effective_until,
    factor_mode:r.factor_mode,factor_value:r.factor_value,factor_date:r.factor_date,components:r.components,
  }))
  const {data,error}=await ctx.supabase.rpc('import_smart_commercial_rows',{
   p_organization:ctx.membership.organization_id,
   p_production_origin:origin,
   p_provider:origin==='third_party'?provider:null,
   p_policy_version:policy||null,
   p_rows:payload
  })
  if(error)return Response.json({error:error.message||'Importação recusada pelo banco de dados.'},{status:400})
  return Response.json({ok:true,result:data,summary:parsed.summary})
 }catch{
  return Response.json({error:'Não foi possível concluir a importação.'},{status:500})
 }
}
