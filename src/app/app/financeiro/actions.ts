'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const SOURCES=new Set(['bank_report','partner_report','payment_evidence','manual_review'])

// Messages shown to the operator. Raw database errors are never echoed (they can name internal objects/tenants).
const REVERSAL_ERRORS:Record<string,string>={
 event_not_found:'Evento não encontrado.',forbidden:'Seu perfil não pode reverter fatos financeiros.',
 reversal_exceeds_original:'A soma das reversões não pode ultrapassar o valor original.',
 cannot_reverse_a_reversal_or_adjustment:'Uma reversão não pode ser revertida.',
 invalid_reversal_amount:'Valor de reversão inválido.',reversal_reason_required:'Informe o motivo.',
 reversal_source_required:'Escolha a fonte da evidência.',reversal_reference_required:'Informe a referência da evidência.'
}

function fail(path:string,code:string):never{redirect(`${path}?erro=${encodeURIComponent(code)}`)}

function parseMoney(raw:string):string|null{
 const v=raw.trim().replace(/\s/g,'')
 const normalized=v.includes(',')?v.replace(/\./g,'').replace(',','.'):v
 return /^\d{1,12}(\.\d{1,2})?$/.test(normalized)&&Number(normalized)>0?normalized:null
}

export async function reverseFinancialEvent(formData:FormData){
 const caseId=String(formData.get('case_id')??'')
 const path=`/app/financeiro/casos/${UUID.test(caseId)?caseId:''}`
 const eventId=String(formData.get('event_id')??'')
 const reason=String(formData.get('reason')??'').trim()
 const sourceKind=String(formData.get('source_kind')??'')
 const sourceReference=String(formData.get('source_reference')??'').trim()
 const amount=parseMoney(String(formData.get('amount')??''))
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))fail(path,'forbidden')
 if(!UUID.test(caseId)||!UUID.test(eventId))fail('/app/financeiro','invalid_request')
 if(!amount)fail(path,'invalid_reversal_amount')
 if(!SOURCES.has(sourceKind))fail(path,'reversal_source_required')
 // tenant is derived by the database from the reversed event; nothing tenant-related is sent from the client
 const {error}=await supabase.rpc('publish_financial_reversal',{p_event_id:eventId,p_amount:amount,p_reason:reason,p_source_kind:sourceKind,p_source_reference:sourceReference})
 if(error){
  const known=Object.keys(REVERSAL_ERRORS).find(k=>error.message?.includes(k))
  fail(path,known??'reversal_failed')
 }
 revalidatePath(path);revalidatePath('/app/financeiro')
 redirect(`${path}?ok=reversal`)
}

export async function resolveReconciliationCase(formData:FormData){
 const caseId=String(formData.get('case_id')??'')
 const note=String(formData.get('resolution_note')??'').trim()
 const path=`/app/financeiro/casos/${UUID.test(caseId)?caseId:''}`
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))fail(path,'forbidden')
 if(!UUID.test(caseId))fail('/app/financeiro','invalid_request')
 if(note.length<10)fail(path,'resolution_note_required')
 if(note.length>2000)fail(path,'resolution_note_too_long')
 // Only status + note are sent. Amounts are derived from the ledger and rejected by the database guard if touched;
 // resolved_by / resolved_at are stamped by the database from the session, never by the client.
 const {data,error}=await supabase.from('financial_reconciliation_cases').update({status:'resolved',resolution_note:note}).eq('id',caseId).select('id')
 if(error||!data?.length)fail(path,'resolution_failed')
 revalidatePath(path);revalidatePath('/app/financeiro')
 redirect(`${path}?ok=resolved`)
}
