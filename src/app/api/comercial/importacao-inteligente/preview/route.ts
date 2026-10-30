
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { parseBankChoice, parseBaseChoice, parseRepassMap, parseSmartCommercialFile, SMART_IMPORT_ISSUES } from '@/lib/imports/smart-commercial-server'
import { safeFileName } from '@/lib/imports/file-guards'

export const dynamic='force-dynamic'

export async function POST(req:Request){
 try{
  const ctx=await requireAppContext()
  if(!atLeast(ctx.membership.role,'manager'))return Response.json({error:'Sem permissão.'},{status:403})
  const fd=await req.formData()
  const file=fd.get('file')
  if(!(file instanceof File))return Response.json({error:'Envie um arquivo.'},{status:400})
  const parsed=await parseSmartCommercialFile(ctx,file,parseRepassMap(fd.get('repass_map')),parseBaseChoice(fd.get('calculation_base')),parseBankChoice(fd.get('bank_id')))
  const hard=parsed.issues.filter(x=>x.code!=='generic_repass_requires_mapping'&&x.code!=='calculation_base_required'&&x.code!=='bank_choice_required')
  return Response.json({
   ok:hard.length===0,
   fileName:safeFileName(file.name),
   format:parsed.format,
   needsReview:parsed.issues.some(x=>x.code.startsWith('pdf_')),
   summary:parsed.summary,
   // Earliest "Vigência Inicial" of the file: suggested start when publishing right after the import.
   validFrom:parsed.rows.reduce<string|null>((m,r)=>{const d=r.effective_from?.slice(0,10)??null;return d&&(!m||d<m)?d:m},null),
   groupOptions:parsed.groupOptions,
   issues:parsed.issues.map(x=>({...x,message:SMART_IMPORT_ISSUES[x.code]??x.code})),
   sample:parsed.rows.slice(0,8).map(r=>({
    bank:r.bank_name,agreement:r.agreement_name,table:r.table_name,contract:r.contract_type_name,
    term:r.term,rate:r.rate,factor:r.factor_value,components:r.components.length,
    values:r.components.map(c=>c.value_kind==='percentage'?`${c.received_value.replace('.',',')}%`:`R$ ${c.received_value.replace('.',',')}`).join(' + '),groupValues:r.group_values.length
   })),
  })
 }catch(e){
  const m=e instanceof Error?e.message:'unexpected'
  return Response.json({error:m==='invalid_file'?'Arquivo vazio ou maior que 5 MB.':'Não foi possível ler o arquivo.'},{status:400})
 }
}
