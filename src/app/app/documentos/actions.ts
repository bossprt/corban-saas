'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { storeCustomerDocument } from '@/lib/documents.server'
import { feedbackUrl, type FeedbackCode } from '@/lib/feedback'

// Sent from the client file, the answer goes back there (only that app path is accepted).
const BACK = /^\/app\/clientes\/[0-9a-f-]{36}$/

export async function uploadCustomerDocument(formData: FormData) {
  const { supabase, user, membership } = await requireAppContext()
  const backTo = String(formData.get('back') ?? '')
  const to = BACK.test(backTo) ? backTo : '/app/documentos'
  const go = (code: FeedbackCode): never => redirect(feedbackUrl(to, code))
  const customerId = String(formData.get('customer_id') ?? '')
  const documentTypeId = String(formData.get('document_type_id') ?? '')
  const file = formData.get('file')
  if (!customerId || !documentTypeId || !(file instanceof File)) return go('erro:doc_invalido')
  const r = await storeCustomerDocument({ supabase, userId: user.id, organizationId: membership.organization_id }, customerId, documentTypeId, file)
  if (!r.ok) return go(r.code)
  revalidatePath('/app/documentos'); revalidatePath(`/app/clientes/${customerId}`)
  return go('ok:doc_enviado')
}
