'use server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isValidCpf } from '@/lib/cpf'
import { normalizeCep } from '@/lib/cep'

const go = (code: FeedbackCode): never => redirect(feedbackUrl('/app/clientes', code))

// One client per CPF: an existing CPF is recognized and updated (upsert_client), never duplicated.
export async function createCustomer(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const fullName = String(formData.get('full_name') ?? '').trim()
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  const phone = String(formData.get('phone') ?? '').trim() || null
  const email = String(formData.get('email') ?? '').trim().toLowerCase() || null

  if (fullName.length < 3) return go('erro:nome_invalido')
  if (!isValidCpf(cpf)) return go('erro:cpf_invalido')
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return go('erro:email_invalido')
  const zip = String(formData.get('zip') ?? '').trim()
  if (zip && !normalizeCep(zip)) return go('erro:cep_invalido')

  const { data, error } = await supabase.rpc('upsert_client', {
    p_org: organization.id, p_cpf: cpf, p_full_name: fullName, p_phone: phone, p_email: email, p_source: 'manual',
  })
  if (error) return go(classifyDbFeedback(error))
  const row = (Array.isArray(data) ? data[0] : data) as { client_id: string; created: boolean; visible: boolean } | null
  if (!row) return go('erro:inesperado')
  revalidatePath('/app/clientes')
  revalidatePath('/app')
  if (!row.visible) return go('ok:cliente_de_outro')

  const detail = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${row.client_id}`, code))
  // The address is optional and secondary: a failure never undoes the client (the person saves it from the client page).
  if (zip && (await persistAddress(supabase, organization.id, row.client_id, formData))) return detail('ok:cliente_endereco_pendente')
  return detail(row.created ? 'ok:cliente_cadastrado' : 'ok:cliente_reconhecido')
}

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']
const val = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const cap = (v: string, n: number) => (v ? v.slice(0, n) : null)
// The address is saved in customer_addresses (already LIVE: composite tenant FK to clients + member RLS), as the customer's PRIMARY address: update it if it exists,
// otherwise insert it. Returns null on success or a feedback code. The tenant is the active organization; the database FK refuses a customer of another tenant.
async function persistAddress(supabase: Supa, organizationId: string, clientId: string, f: FormData): Promise<FeedbackCode | null> {
  const zip = normalizeCep(val(f, 'zip'))
  if (!zip) return 'erro:cep_invalido'
  const state = val(f, 'state').toUpperCase()
  if (state && !/^[A-Z]{2}$/.test(state)) return 'erro:estado_invalido'
  const row = { postal_code: zip, street: cap(val(f, 'street'), 160), number: cap(val(f, 'number'), 20), complement: cap(val(f, 'complement'), 80), neighborhood: cap(val(f, 'district'), 120), city: cap(val(f, 'city'), 120), state: state || null }
  const { data: existing, error: readError } = await supabase.from('customer_addresses').select('id').eq('customer_id', clientId).eq('is_primary', true).limit(1).maybeSingle()
  if (readError) return classifyDbFeedback(readError)
  const { error } = existing
    ? await supabase.from('customer_addresses').update(row).eq('id', existing.id as string)
    : await supabase.from('customer_addresses').insert({ organization_id: organizationId, customer_id: clientId, is_primary: true, ...row })
  return error ? classifyDbFeedback(error) : null
}

export async function saveCustomerAddress(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const id = val(formData, 'client_id')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${encodeURIComponent(id)}`, code))
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return go('erro:requisicao_invalida')
  const failure = await persistAddress(supabase, organization.id, id, formData)
  if (failure) return back(failure)
  revalidatePath(`/app/clientes/${id}`)
  return back('ok:endereco_salvo')
}
