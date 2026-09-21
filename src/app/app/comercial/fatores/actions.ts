'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { xlsxRows } from '@/lib/commercial-xlsx'
import { parseDelimited } from '@/lib/commercial'

const PATH='/app/comercial/fatores'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const go=(code:FeedbackCode):never=>{revalidatePath(PATH);return redirect(feedbackUrl(PATH,code))}
const manager=async()=>{const ctx=await requireAppContext();return atLeast(ctx.membership.role,'manager')?ctx:null}
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
const number=(v:string)=>{let x=v.trim().replace(/\s/g,'').replace('%','');if(x.includes(',')&&!x.includes('.'))x=x.replace(',','.');else if(x.includes(',')&&x.includes('.'))x=x.replace(/\./g,'').replace(',','.');const n=Number(x);return Number.isFinite(n)?n:null}
const norm=(v:string)=>v.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]/g,'')
const aliases={
 min:['prazoinicial','prazomin','prazominimo','de','inicio'],
 max:['prazofinal','prazomax','prazomaximo','ate','fim'],
 factor:['fator','coeficiente','factor']
}
const col=(headers:string[],names:string[])=>headers.findIndex(h=>names.includes(norm(h)))

export async function createFactorProfile(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const name=text(f,'name'),bank=text(f,'org_bank_id'),agreement=text(f,'org_agreement_id'),table=text(f,'product_table_id'),contract=text(f,'contract_type_id'),mode=text(f,'factor_mode')
 if(name.length<1||name.length>120||!uuid(bank)||!['daily','fixed'].includes(mode)||(agreement&&!uuid(agreement))||(table&&!uuid(table))||(contract&&!uuid(contract)))return go('erro:fator_invalido')
 const {error}=await ctx.supabase.from('commercial_factor_profiles').insert({
  organization_id:ctx.membership.organization_id,name,org_bank_id:bank,org_agreement_id:agreement||null,product_table_id:table||null,contract_type_id:contract||null,factor_mode:mode
 })
 return error?go(classifyDbFeedback(error)):go('ok:fator_perfil_cadastrado')
}

async function createBatch(ctx:NonNullable<Awaited<ReturnType<typeof manager>>>,profile:string,effective:string,rows:{term_min:number;term_max:number;factor_value:number}[],source:'manual'|'file',note:string|null){
 const rev=await ctx.supabase.from('commercial_factor_batches').select('revision').eq('profile_id',profile).eq('effective_date',effective).order('revision',{ascending:false}).limit(1).maybeSingle()
 const ins=await ctx.supabase.from('commercial_factor_batches').insert({
  organization_id:ctx.membership.organization_id,profile_id:profile,effective_date:effective,revision:(rev.data?.revision??0)+1,status:'draft',source_kind:source,source_note:note
 }).select('id').single()
 if(ins.error||!ins.data)return ins.error??new Error('batch_insert_failed')
 const payload=rows.map(r=>({...r,organization_id:ctx.membership.organization_id,batch_id:ins.data.id}))
 const entries=await ctx.supabase.from('commercial_factor_entries').insert(payload)
 if(entries.error)return entries.error
 const pub=await ctx.supabase.rpc('publish_commercial_factor_batch',{p_batch:ins.data.id})
 return pub.error
}

export async function createManualFactor(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const profile=text(f,'profile_id'),effective=text(f,'effective_date'),min=number(text(f,'term_min')),max=number(text(f,'term_max')),factor=number(text(f,'factor_value'))
 if(!uuid(profile)||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(effective)||!Number.isInteger(min)||!Number.isInteger(max)||min!<1||max!<min!||factor===null||factor<=0)return go('erro:fator_invalido')
 const error=await createBatch(ctx,profile,effective,[{term_min:min!,term_max:max!,factor_value:factor}], 'manual',null)
 return error?go(classifyDbFeedback(error)):go('ok:fator_publicado')
}

export async function importFactorFile(f:FormData){
 const ctx=await manager();if(!ctx)return go('erro:sem_permissao')
 const profile=text(f,'profile_id'),effective=text(f,'effective_date'),file=f.get('file')
 if(!uuid(profile)||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(effective)||!(file instanceof File)||file.size===0||file.size>2_000_000)return go('erro:fator_arquivo')
 const buf=Buffer.from(await file.arrayBuffer())
 let rows:string[][]
 try{const isXlsx=/\.xlsx$/i.test(file.name)||(buf[0]===0x50&&buf[1]===0x4b);rows=isXlsx?await xlsxRows(buf):parseDelimited(buf.toString('utf-8'))}catch{return go('erro:fator_arquivo')}
 if(rows.length<2)return go('erro:fator_arquivo')
 const headers=rows[0],iMin=col(headers,aliases.min),iMax=col(headers,aliases.max),iFactor=col(headers,aliases.factor)
 if(iMin<0||iFactor<0)return go('erro:fator_colunas')
 const parsed:{term_min:number;term_max:number;factor_value:number}[]=[]
 for(const r of rows.slice(1)){
  const min=number(r[iMin]??''), max=iMax>=0?number(r[iMax]??''):min, factor=number(r[iFactor]??'')
  if(!Number.isInteger(min)||!Number.isInteger(max)||min!<1||max!<min!||factor===null||factor<=0)return go('erro:fator_colunas')
  parsed.push({term_min:min!,term_max:max!,factor_value:factor})
 }
 if(!parsed.length||parsed.length>500)return go('erro:fator_arquivo')
 const error=await createBatch(ctx,profile,effective,parsed,'file',file.name.slice(0,180))
 return error?go(classifyDbFeedback(error)):go('ok:fatores_importados')
}
