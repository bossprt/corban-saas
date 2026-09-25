'use server'

import { createHash, randomUUID } from 'crypto'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { checkUpload, safeFileName } from '@/lib/documents'
import { feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const BUCKET = 'corban-documents'
const go = (code: FeedbackCode): never => redirect(feedbackUrl('/app/documentos', code))

export async function uploadCustomerDocument(formData: FormData) {
  const { supabase, user, membership } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const documentTypeId = String(formData.get('document_type_id') ?? '')
  const file = formData.get('file')
  if (!customerId || !documentTypeId || !(file instanceof File)) return go('erro:doc_invalido')

  const bytes = Buffer.from(await file.arrayBuffer())
  // Size, emptiness and the REAL type (first bytes, not the browser's claim) are decided before anything touches the database or Storage.
  const check = checkUpload(file.size, file.type, bytes)
  if (!check.ok) return go(check.code)

  const [{ data: customer }, { data: documentType }] = await Promise.all([
    supabase.from('clients').select('id').eq('id', customerId).is('deleted_at', null).maybeSingle(),
    supabase.from('document_types').select('id').eq('id', documentTypeId).eq('is_active', true).maybeSingle(),
  ])
  if (!customer || !documentType) return go('erro:doc_indisponivel')

  const sha256 = createHash('sha256').update(bytes).digest('hex')
  const { data: duplicate } = await supabase.from('customer_documents').select('id').eq('customer_id', customerId).eq('sha256', sha256).maybeSingle()
  if (duplicate) return go('erro:doc_duplicado')

  const { data: latest } = await supabase.from('customer_documents')
    .select('version').eq('customer_id', customerId).eq('document_type_id', documentTypeId)
    .order('version', { ascending: false }).limit(1).maybeSingle()
  const version = (latest?.version ?? 0) + 1

  const path = `${membership.organization_id}/${customerId}/${randomUUID()}/${safeFileName(file.name)}`
  const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, bytes, { contentType: check.mime, upsert: false })
  if (uploadError) return go('erro:doc_armazenamento')

  const { error: recordError } = await supabase.from('customer_documents').insert({
    organization_id: membership.organization_id, customer_id: customerId, document_type_id: documentTypeId, version,
    storage_bucket: BUCKET, storage_path: path, original_file_name: safeFileName(file.name), mime_type: check.mime, file_size_bytes: file.size, sha256, uploaded_by: user.id,
  })
  // Storage evidence is intentionally non-deletable by authenticated users. A rare DB failure after upload leaves a tenant-isolated orphan for
  // privileged maintenance, never a false database record.
  if (recordError) return go('erro:doc_registro')

  revalidatePath('/app/documentos')
  return go('ok:doc_enviado')
}
