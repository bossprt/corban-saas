'use server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isValidCpf } from '@/lib/cpf'
import { normalizeCep } from '@/lib/cep'
import { parseMoneyInput } from '@/lib/money-input'

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
  // Birth date on the first registration only (an existing client keeps its profile; it is edited on the client page).
  const birth = String(formData.get('birth_date') ?? '')
  if (row.created && /^\d{4}-\d{2}-\d{2}$/.test(birth)) {
    const { error: birthError } = await supabase.rpc('update_client_profile', { p_client: row.client_id, p_birth_date: birth, p_father_name: null, p_mother_name: null,
      p_rg_number: null, p_rg_issuer: null, p_rg_state: null, p_rg_issued_on: null, p_gender: null, p_marital_status: null, p_birthplace_city: null, p_birthplace_state: null, p_whatsapp: null })
    if (birthError) return detail('erro:ficha_nascimento')
  }
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

// ---- Client profile (ADR-0033): personal data, bank accounts and registrations, all through governed RPCs ----------------
const isId = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)
const orNull = (f: FormData, k: string) => val(f, k) || null
const dateOrNull = (f: FormData, k: string) => (/^\d{4}-\d{2}-\d{2}$/.test(val(f, k)) ? val(f, k) : null)
function profileError(m: string): FeedbackCode | null {
  if (/invalid_birth_date/.test(m)) return 'erro:ficha_nascimento'
  if (/invalid_rg_issued_on/.test(m)) return 'erro:ficha_emissao'
  if (/invalid_state/.test(m)) return 'erro:estado_invalido'
  if (/invalid_whatsapp/.test(m)) return 'erro:ficha_whatsapp'
  if (/invalid_bank_code|invalid_bank_name|invalid_branch|invalid_account/.test(m)) return 'erro:ficha_conta'
  if (/bank_account_in_use/.test(m)) return 'erro:ficha_conta_pix'
  if (/registration_already_exists/.test(m)) return 'erro:ficha_matricula_existe'
  if (/invalid_registration_number/.test(m)) return 'erro:ficha_matricula'
  if (/invalid_margin/.test(m)) return 'erro:valor_invalido'
  if (/agreement_not_found/.test(m)) return 'erro:ficha_convenio'
  return null
}

export async function updateClientProfile(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = val(formData, 'client_id')
  if (!isId(id)) return go('erro:requisicao_invalida')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${id}`, code))
  const { error } = await supabase.rpc('update_client_profile', {
    p_client: id, p_birth_date: dateOrNull(formData, 'birth_date'), p_father_name: orNull(formData, 'father_name'), p_mother_name: orNull(formData, 'mother_name'),
    p_rg_number: orNull(formData, 'rg_number'), p_rg_issuer: orNull(formData, 'rg_issuer'), p_rg_state: orNull(formData, 'rg_state'),
    p_rg_issued_on: dateOrNull(formData, 'rg_issued_on'), p_gender: orNull(formData, 'gender'), p_marital_status: orNull(formData, 'marital_status'),
    p_birthplace_city: orNull(formData, 'birthplace_city'), p_birthplace_state: orNull(formData, 'birthplace_state'),
    p_whatsapp: formData.get('whatsapp_same') === 'on' ? orNull(formData, 'phone') : orNull(formData, 'whatsapp'),
  })
  if (error) return back(profileError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(`/app/clientes/${id}`)
  return back('ok:ficha_salva')
}

export async function addClientBankAccount(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = val(formData, 'client_id')
  if (!isId(id)) return go('erro:requisicao_invalida')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${id}`, code))
  const clean = (k: string) => val(formData, k).replace(/[^0-9Xx-]/g, '')
  const { error } = await supabase.rpc('add_client_bank_account', {
    p_client: id, p_bank_code: clean('bank_code'), p_bank_name: val(formData, 'bank_name'), p_branch: clean('branch'),
    p_account_number: val(formData, 'account_number').replace(/\D/g, ''), p_account_digit: clean('account_digit') || null,
    p_account_type: val(formData, 'account_type'), p_primary: formData.get('is_primary') === 'on',
  })
  if (error) return back(profileError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(`/app/clientes/${id}`)
  return back('ok:ficha_conta_salva')
}

export async function setClientBankAccount(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = val(formData, 'client_id'), account = val(formData, 'account_id'), action = val(formData, 'action')
  if (!isId(id) || !isId(account) || !['primary', 'remove'].includes(action)) return go('erro:requisicao_invalida')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${id}`, code))
  const { error } = await supabase.rpc('set_client_bank_account', { p_account: account, p_action: action })
  if (error) return back(profileError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(`/app/clientes/${id}`)
  return back('ok:ficha_conta_salva')
}

export async function saveClientRegistration(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = val(formData, 'client_id'), registration = val(formData, 'registration_id'), agreement = val(formData, 'agreement_id')
  if (!isId(id) || (registration && !isId(registration)) || !isId(agreement)) return go('erro:requisicao_invalida')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${id}`, code))
  const margin = parseMoneyInput(formData.get('margin_amount'))
  if (margin === 'invalid') return back('erro:valor_invalido')
  const password = String(formData.get('portal_password') ?? '')
  const { error } = await supabase.rpc('save_client_registration', {
    p_client: id, p_registration: registration || null, p_agreement: agreement, p_agency_name: orNull(formData, 'agency_name'),
    p_registration_number: val(formData, 'registration_number'), p_status: val(formData, 'status') || 'active', p_margin_amount: margin,
    p_margin_as_of: margin ? dateOrNull(formData, 'margin_as_of') : null, p_portal_login: orNull(formData, 'portal_login'),
    p_password: password === '' ? null : password, p_clear_password: formData.get('clear_password') === 'on', p_notes: orNull(formData, 'notes'),
  })
  if (error) return back(profileError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(`/app/clientes/${id}`)
  return back('ok:ficha_matricula_salva')
}

// Returns the password to the screen (never through a URL). The database checks the permission and records the access.
export async function revealRegistrationPassword(registrationId: string): Promise<{ password?: string | null; error?: string }> {
  const { supabase } = await requireAppContext()
  if (!isId(registrationId)) return { error: 'Pedido inválido.' }
  const { data, error } = await supabase.rpc('reveal_registration_password', { p_registration: registrationId })
  if (error) return { error: /not_authorized/.test(error.message ?? '') ? 'Seu papel não pode ver esta senha.' : 'Não foi possível mostrar a senha.' }
  return { password: (data as string | null) ?? null }
}
