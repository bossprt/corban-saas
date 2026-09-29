import 'server-only'
import { createHash, randomUUID } from 'crypto'
import type { SupabaseClient } from '@supabase/supabase-js'
import { checkUpload, safeFileName } from '@/lib/documents'
import type { FeedbackCode } from '@/lib/feedback'

const BUCKET = 'corban-documents'

// Stores one client document (private Storage + versioned record). Shared by the Documentos page, the client file and the
// proposal checklist. Size, emptiness and the REAL type (first bytes, not the browser's claim) are checked before anything is written.
export async function storeCustomerDocument(
  ctx: { supabase: SupabaseClient; userId: string; organizationId: string },
  customerId: string, documentTypeId: string, file: File,
): Promise<{ ok: true; id: string } | { ok: false; code: FeedbackCode }> {
  const { supabase } = ctx
  const bytes = Buffer.from(await file.arrayBuffer())
  const check = checkUpload(file.size, file.type, bytes)
  if (!check.ok) return { ok: false, code: check.code }

  const [{ data: customer }, { data: documentType }] = await Promise.all([
    supabase.from('clients').select('id').eq('id', customerId).is('deleted_at', null).maybeSingle(),
    supabase.from('document_types').select('id').eq('id', documentTypeId).eq('is_active', true).maybeSingle(),
  ])
  if (!customer || !documentType) return { ok: false, code: 'erro:doc_indisponivel' }

  const sha256 = createHash('sha256').update(bytes).digest('hex')
  const { data: duplicate } = await supabase.from('customer_documents').select('id').eq('customer_id', customerId).eq('sha256', sha256).maybeSingle()
  if (duplicate) return { ok: false, code: 'erro:doc_duplicado' }

  const { data: latest } = await supabase.from('customer_documents')
    .select('version').eq('customer_id', customerId).eq('document_type_id', documentTypeId)
    .order('version', { ascending: false }).limit(1).maybeSingle()
  const version = (latest?.version ?? 0) + 1

  const path = `${ctx.organizationId}/${customerId}/${randomUUID()}/${safeFileName(file.name)}`
  const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, bytes, { contentType: check.mime, upsert: false })
  if (uploadError) return { ok: false, code: 'erro:doc_armazenamento' }

  const { data: row, error: recordError } = await supabase.from('customer_documents').insert({
    organization_id: ctx.organizationId, customer_id: customerId, document_type_id: documentTypeId, version,
    storage_bucket: BUCKET, storage_path: path, original_file_name: safeFileName(file.name), mime_type: check.mime, file_size_bytes: file.size, sha256, uploaded_by: ctx.userId,
  }).select('id').single()
  // Storage evidence is intentionally non-deletable by authenticated users. A rare DB failure after upload leaves a tenant-isolated orphan for
  // privileged maintenance, never a false database record.
  if (recordError || !row) return { ok: false, code: 'erro:doc_registro' }
  return { ok: true, id: row.id }
}
