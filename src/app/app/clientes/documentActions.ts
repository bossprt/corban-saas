'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { storeCustomerDocument } from '@/lib/documents.server'
import { feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// Document sent from the client file (Documentos card); the answer goes back to that file.
export async function uploadCustomerDocument(formData: FormData) {
  const { supabase, user, membership } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const documentTypeId = String(formData.get('document_type_id') ?? '')
  const file = formData.get('file')
  if (!UUID.test(customerId)) return redirect(feedbackUrl('/app/clientes', 'erro:doc_invalido'))
  const go = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${customerId}`, code))
  if (!documentTypeId || !(file instanceof File)) return go('erro:doc_invalido')
  const r = await storeCustomerDocument({ supabase, userId: user.id, organizationId: membership.organization_id }, customerId, documentTypeId, file)
  if (!r.ok) return go(r.code)
  revalidatePath(`/app/clientes/${customerId}`)
  return go('ok:doc_enviado')
}
