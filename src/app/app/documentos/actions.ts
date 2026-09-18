'use server'

import { createHash, randomUUID } from 'crypto'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

const BUCKET = 'corban-documents'
const MAX_BYTES = 15 * 1024 * 1024
const ALLOWED = new Set(['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])

function safeFileName(name: string) {
  const cleaned = name.normalize('NFKD').replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/-+/g, '-')
  return cleaned.slice(-120) || 'document'
}

export async function uploadCustomerDocument(formData: FormData) {
  const { supabase, user, membership } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const documentTypeId = String(formData.get('document_type_id') ?? '')
  const file = formData.get('file')

  if (!customerId || !documentTypeId || !(file instanceof File) || file.size === 0) {
    throw new Error('Cliente, tipo e arquivo são obrigatórios.')
  }
  if (file.size > MAX_BYTES) throw new Error('Arquivo excede 15 MiB.')
  if (!ALLOWED.has(file.type)) throw new Error('Formato não permitido.')

  const [{ data: customer }, { data: documentType }] = await Promise.all([
    supabase.from('clients').select('id').eq('id', customerId).is('deleted_at', null).maybeSingle(),
    supabase.from('document_types').select('id').eq('id', documentTypeId).eq('is_active', true).maybeSingle(),
  ])
  if (!customer || !documentType) throw new Error('Cliente ou tipo de documento indisponível.')

  const bytes = Buffer.from(await file.arrayBuffer())
  const sha256 = createHash('sha256').update(bytes).digest('hex')

  const { data: duplicate } = await supabase.from('customer_documents')
    .select('id').eq('customer_id', customerId).eq('sha256', sha256).maybeSingle()
  if (duplicate) throw new Error('Este arquivo já está registrado para o cliente.')

  const { data: latest } = await supabase.from('customer_documents')
    .select('version').eq('customer_id', customerId).eq('document_type_id', documentTypeId)
    .order('version', { ascending: false }).limit(1).maybeSingle()
  const version = (latest?.version ?? 0) + 1

  const path = `${membership.organization_id}/${customerId}/${randomUUID()}/${safeFileName(file.name)}`
  const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, bytes, {
    contentType: file.type,
    upsert: false,
  })
  if (uploadError) throw new Error('Falha ao armazenar o arquivo privado.')

  const { error: recordError } = await supabase.from('customer_documents').insert({
    organization_id: membership.organization_id,
    customer_id: customerId,
    document_type_id: documentTypeId,
    version,
    storage_bucket: BUCKET,
    storage_path: path,
    original_file_name: file.name,
    mime_type: file.type,
    file_size_bytes: file.size,
    sha256,
    uploaded_by: user.id,
  })

  // Storage evidence is intentionally non-deletable by authenticated users.
  // A rare DB failure after upload leaves a tenant-isolated orphan for privileged maintenance,
  // never a false database record.
  if (recordError) throw new Error('Arquivo armazenado, mas o registro falhou. Não reenvie; solicite reconciliação.')

  revalidatePath('/app/documentos')
}
