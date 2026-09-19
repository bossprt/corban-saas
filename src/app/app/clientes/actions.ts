'use server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isValidCpf } from '@/lib/cpf'

const go = (code: FeedbackCode): never => redirect(feedbackUrl('/app/clientes', code))

export async function createCustomer(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const fullName = String(formData.get('full_name') ?? '').trim()
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  const phone = String(formData.get('phone') ?? '').trim() || null
  const email = String(formData.get('email') ?? '').trim().toLowerCase() || null

  if (fullName.length < 3) return go('erro:nome_invalido')
  if (!isValidCpf(cpf)) return go('erro:cpf_invalido')
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return go('erro:email_invalido')

  // The organization is explicit and validated by the database against an active membership.
  const { error } = await supabase.rpc('create_customer_with_timeline', {
    p_organization_id: organization.id, p_full_name: fullName, p_cpf: cpf, p_phone: phone, p_email: email, p_original_source: 'corban_os',
  })
  if (error) return go(classifyDbFeedback(error))
  revalidatePath('/app/clientes')
  revalidatePath('/app')
  return go('ok:cliente_cadastrado')
}
