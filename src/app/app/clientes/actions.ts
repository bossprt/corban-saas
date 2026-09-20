'use server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isValidCpf } from '@/lib/cpf'
import { normalizeCep } from '@/lib/cep'

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
  const zip = String(formData.get('zip') ?? '').trim()
  if (zip && !normalizeCep(zip)) return go('erro:cep_invalido')
  const { error } = await supabase.rpc('create_customer_with_timeline', {
    p_organization_id: organization.id, p_full_name: fullName, p_cpf: cpf, p_phone: phone, p_email: email, p_original_source: 'corban_os',
  })
  if (error) return go(classifyDbFeedback(error))
  revalidatePath('/app/clientes')
  revalidatePath('/app')
  // The address is optional and secondary: the customer already exists, so a failure here never undoes it (the person is told and can save it from the customer page).
  if (zip) {
    const { data: created } = await supabase.from('clients').select('id').eq('cpf', cpf).is('deleted_at', null).maybeSingle()
    if (!created) return go('ok:cliente_endereco_pendente')
    const saved = await persistAddress(supabase, created.id as string, formData)
    if (saved) return go('ok:cliente_endereco_pendente')
  }
  return go('ok:cliente_cadastrado')
}

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']
const val = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
// Returns null on success, or a feedback code. The database validates zip/UF/source again and derives the tenant from the customer.
async function persistAddress(supabase: Supa, clientId: string, f: FormData): Promise<FeedbackCode | null> {
  const source = val(f, 'address_source')
  const { error } = await supabase.rpc('save_customer_address', {
    p_client: clientId, p_zip: val(f, 'zip'), p_street: val(f, 'street'), p_number: val(f, 'number'), p_complement: val(f, 'complement'),
    p_district: val(f, 'district'), p_city: val(f, 'city'), p_state: val(f, 'state'), p_source: ['manual', 'cep_lookup', 'cep_lookup_edited'].includes(source) ? source : 'manual',
  })
  return error ? classifyDbFeedback(error) : null
}

export async function saveCustomerAddress(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = val(formData, 'client_id')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${encodeURIComponent(id)}`, code))
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return go('erro:requisicao_invalida')
  if (!normalizeCep(val(formData, 'zip'))) return back('erro:cep_invalido')
  if (val(formData, 'state') && !/^[A-Za-z]{2}$/.test(val(formData, 'state'))) return back('erro:estado_invalido')
  const failure = await persistAddress(supabase, id, formData)
  if (failure) return back(failure)
  revalidatePath(`/app/clientes/${id}`)
  return back('ok:endereco_salvo')
}
