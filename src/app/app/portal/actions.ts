'use server'

import { createHash, randomUUID } from 'crypto'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { checkUpload, safeFileName } from '@/lib/documents'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { isUuid } from '@/lib/team'

const BUCKET = 'corban-documents'
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()

// Broker sends a proposal (F7). The database decides everything: seller profile, CPF, table, duplicates, and it never
// reveals whether the CPF was already a client.
export async function submitPortalProposal(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const back = (code: FeedbackCode): never => redirect(feedbackUrl('/app/portal/nova', code))
  const table = text(formData, 'table_version_id')
  if (!isUuid(table)) return back('erro:requisicao_invalida')
  const requested = parseMoneyInput(formData.get('requested_amount'))
  const released = parseMoneyInput(formData.get('released_amount'))
  const installment = parseMoneyInput(formData.get('installment_amount'))
  if (requested === 'invalid' || released === 'invalid' || installment === 'invalid' || (!requested && !released)) return back('erro:valor_invalido')
  const termText = text(formData, 'term')
  const term = termText ? Number.parseInt(termText, 10) : null
  if (termText && (!Number.isInteger(term) || term! < 1 || term! > 420)) return back('erro:prazo_invalido')

  const { data, error } = await supabase.rpc('submit_broker_proposal', {
    p_org: organization.id, p_cpf: text(formData, 'cpf'), p_full_name: text(formData, 'full_name'), p_phone: text(formData, 'phone') || null,
    p_email: text(formData, 'email') || null, p_table_version_id: table, p_requested_amount: requested, p_released_amount: released,
    p_installment_amount: installment, p_term: term, p_ade: text(formData, 'ade') || null,
  })
  if (error) {
    const m = error.message ?? ''
    if (/seller_profile_required/.test(m)) return back('erro:portal_vendedor')
    if (/proposal_already_exists/.test(m)) return back('erro:portal_ja_existe')
    if (/invalid_ade/.test(m)) return back('erro:ade_invalido')
    if (/invalid_amount|amount_required/.test(m)) return back('erro:valor_invalido')
    if (/invalid_term/.test(m)) return back('erro:prazo_invalido')
    return back(classifyDbFeedback(error))
  }
  revalidatePath('/app/portal')
  redirect(feedbackUrl(`/app/portal/propostas/${data as string}`, 'ok:portal_enviada'))
}

// A document of a proposal that still waits for validation: stored under <org>/portal/<proposal>/ with the broker's own
// session (the storage policy checks the sender), then recorded by the database.
export async function uploadPortalDocument(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const proposal = text(formData, 'proposal_id')
  if (!isUuid(proposal)) return redirect(feedbackUrl('/app/portal', 'erro:requisicao_invalida'))
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/portal/propostas/${proposal}`, code))
  const labelText = text(formData, 'label')
  const file = formData.get('file')
  if (labelText.length < 2 || labelText.length > 60 || !(file instanceof File)) return back('erro:doc_invalido')
  const bytes = Buffer.from(await file.arrayBuffer())
  const check = checkUpload(file.size, file.type, bytes)
  if (!check.ok) return back(check.code)

  const name = safeFileName(file.name)
  const path = `${organization.id}/portal/${proposal}/${randomUUID()}/${name}`
  const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, bytes, { contentType: check.mime, upsert: false })
  if (uploadError) return back('erro:portal_documento')
  const { error } = await supabase.rpc('record_submission_document', {
    p_proposal: proposal, p_label: labelText, p_path: path, p_file_name: name, p_mime: check.mime, p_size: file.size,
    p_sha256: createHash('sha256').update(bytes).digest('hex'),
  })
  if (error) return back(/duplicate key/.test(error.message ?? '') ? 'erro:doc_duplicado' : 'erro:portal_documento')
  revalidatePath(`/app/portal/propostas/${proposal}`)
  return back('ok:portal_documento')
}
