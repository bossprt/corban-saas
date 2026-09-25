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
  const clientId = row.client_id
  // Single registration form (owner decision): the optional blocks are saved after the client exists. A failure in one of
  // them never undoes the client; the page opens with the message and the person completes it there.
  const failure = await completeNewClient(supabase, organization.id, clientId, row.created, formData)
  if (failure) return detail(failure)
  return detail(row.created ? 'ok:cliente_cadastrado' : 'ok:cliente_reconhecido')
}

const PROFILE_KEYS = ['birth_date', 'father_name', 'mother_name', 'rg_number', 'rg_issuer', 'rg_state', 'rg_issued_on', 'gender', 'marital_status', 'birthplace_city', 'birthplace_state', 'whatsapp'] as const
type ProfileRow = Record<(typeof PROFILE_KEYS)[number], string | null>

// Personal data, address, first bank account and first registration of the single form. For a client that already
// existed, only empty personal data is filled and an existing primary address is kept: nothing is erased.
async function completeNewClient(supabase: Supa, organizationId: string, clientId: string, created: boolean, f: FormData): Promise<FeedbackCode | null> {
  const typed: ProfileRow = {
    birth_date: dateOrNull(f, 'birth_date'), father_name: orNull(f, 'father_name'), mother_name: orNull(f, 'mother_name'), rg_number: orNull(f, 'rg_number'),
    rg_issuer: orNull(f, 'rg_issuer'), rg_state: orNull(f, 'rg_state'), rg_issued_on: dateOrNull(f, 'rg_issued_on'), gender: orNull(f, 'gender'),
    marital_status: orNull(f, 'marital_status'), birthplace_city: orNull(f, 'birthplace_city'), birthplace_state: orNull(f, 'birthplace_state'),
    whatsapp: f.get('whatsapp_same') === 'on' ? orNull(f, 'phone') : orNull(f, 'whatsapp'),
  }
  if (PROFILE_KEYS.some(k => typed[k])) {
    let merged = typed
    if (!created) {
      const { data: current } = await supabase.from('clients').select(PROFILE_KEYS.join(',')).eq('id', clientId).maybeSingle()
      const cur = (current ?? {}) as unknown as Partial<ProfileRow>
      merged = Object.fromEntries(PROFILE_KEYS.map(k => [k, cur[k] ?? typed[k]])) as ProfileRow
    }
    const { error } = await supabase.rpc('update_client_profile', {
      p_client: clientId, p_birth_date: merged.birth_date, p_father_name: merged.father_name, p_mother_name: merged.mother_name, p_rg_number: merged.rg_number,
      p_rg_issuer: merged.rg_issuer, p_rg_state: merged.rg_state, p_rg_issued_on: merged.rg_issued_on, p_gender: merged.gender, p_marital_status: merged.marital_status,
      p_birthplace_city: merged.birthplace_city, p_birthplace_state: merged.birthplace_state, p_whatsapp: merged.whatsapp,
    })
    if (error) return profileError(error.message ?? '') ?? classifyDbFeedback(error)
  }

  if (val(f, 'zip')) {
    const { data: primary } = created ? { data: null } : await supabase.from('customer_addresses').select('id').eq('customer_id', clientId).eq('is_primary', true).limit(1).maybeSingle()
    if (!primary && (await persistAddress(supabase, organizationId, clientId, f))) return 'ok:cliente_endereco_pendente'
  }

  if (await saveRows(supabase, clientId, created, f)) return 'erro:ficha_linhas_recusadas'
  return null
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

// Returns the password to the screen (never through a URL). The database checks the permission and records the access.
export async function revealRegistrationPassword(registrationId: string): Promise<{ password?: string | null; error?: string }> {
  const { supabase } = await requireAppContext()
  if (!isId(registrationId)) return { error: 'Pedido inválido.' }
  const { data, error } = await supabase.rpc('reveal_registration_password', { p_registration: registrationId })
  if (error) return { error: /not_authorized/.test(error.message ?? '') ? 'Seu papel não pode ver esta senha.' : 'Não foi possível mostrar a senha.' }
  return { password: (data as string | null) ?? null }
}

// Accounts and registrations of the single form (create and edit). Rows with an id are updated or removed; rows without an
// id are created when filled. Returns how many rows were refused (the valid ones are saved).
async function saveRows(supabase: Supa, clientId: string, created: boolean, f: FormData): Promise<number> {
  const all = (k: string) => f.getAll(k).map(v => String(v ?? '').trim())
  const cleanOf = (v: string) => v.replace(/[^0-9Xx-]/g, '')
  let refused = 0

  const accIds = all('account_id'), removes = all('remove_account'), codes = all('bank_code'), names = all('bank_name'), branches = all('branch'),
    numbers = all('account_number'), digits = all('account_digit'), types = all('account_type')
  const primaryRow = Number(val(f, 'primary_account') || '0')
  const editing = accIds.some(Boolean)
  // A known client keeps its current primary account when registering again; when editing, the chosen row is the primary one.
  const { data: hasPrimary } = created || editing ? { data: null } : await supabase.from('customer_bank_accounts').select('id').eq('customer_id', clientId).eq('is_primary', true).limit(1).maybeSingle()
  let primaryId: string | null = null
  for (let i = 0; i < Math.max(codes.length, numbers.length, accIds.length); i++) {
    const id = accIds[i] ?? ''
    const account = (numbers[i] ?? '').replace(/\D/g, '')
    if (id && isId(id)) {
      if (removes[i] === '1') {
        const { error } = await supabase.rpc('set_client_bank_account', { p_account: id, p_action: 'remove' })
        if (error) refused++
        continue
      }
      const { error } = await supabase.rpc('update_client_bank_account', { p_account: id, p_bank_code: cleanOf(codes[i] ?? ''), p_bank_name: names[i] ?? '',
        p_branch: cleanOf(branches[i] ?? ''), p_account_number: account, p_account_digit: cleanOf(digits[i] ?? '') || null, p_account_type: types[i] || 'checking' })
      if (error) refused++
      else if (i === primaryRow) primaryId = id
      continue
    }
    if (!codes[i] && !account) continue
    const { data: same } = await supabase.from('customer_bank_accounts').select('id').eq('customer_id', clientId).eq('bank_code', cleanOf(codes[i] ?? ''))
      .eq('branch', cleanOf(branches[i] ?? '')).eq('account_number', account).limit(1).maybeSingle()
    if (same) continue
    const { data: newId, error } = await supabase.rpc('add_client_bank_account', {
      p_client: clientId, p_bank_code: cleanOf(codes[i] ?? ''), p_bank_name: names[i] ?? '', p_branch: cleanOf(branches[i] ?? ''), p_account_number: account,
      p_account_digit: cleanOf(digits[i] ?? '') || null, p_account_type: types[i] || 'checking', p_primary: i === primaryRow && !hasPrimary,
    })
    if (error) refused++
    else if (i === primaryRow && !hasPrimary) primaryId = newId as string
  }
  if (primaryId && editing) {
    const { error } = await supabase.rpc('set_client_bank_account', { p_account: primaryId, p_action: 'primary' })
    if (error) refused++
  }

  const regIds = all('registration_id'), agreements = all('agreement_id'), agencies = all('agency_name'), regNumbers = all('registration_number'),
    statuses = all('registration_status'), margins = f.getAll('margin_amount'), marginDates = all('margin_as_of'), logins = all('portal_login'),
    passwords = f.getAll('portal_password').map(v => String(v ?? '')), clears = all('clear_password')
  for (let i = 0; i < Math.max(agreements.length, regNumbers.length, regIds.length); i++) {
    const id = regIds[i] ?? ''
    if (!id && !agreements[i] && !regNumbers[i]) continue
    const margin = parseMoneyInput(margins[i] ?? null)
    if (!isId(agreements[i] ?? '') || margin === 'invalid' || (id && !isId(id))) { refused++; continue }
    const date = /^\d{4}-\d{2}-\d{2}$/.test(marginDates[i] ?? '') ? marginDates[i] : null
    const { error } = await supabase.rpc('save_client_registration', {
      p_client: clientId, p_registration: id || null, p_agreement: agreements[i], p_agency_name: agencies[i] || null, p_registration_number: regNumbers[i] ?? '',
      p_status: statuses[i] === 'inactive' ? 'inactive' : 'active', p_margin_amount: margin, p_margin_as_of: margin ? date : null, p_portal_login: logins[i] || null,
      p_password: passwords[i] ? passwords[i] : null, p_clear_password: clears[i] === '1', p_notes: null,
    })
    if (error) refused++
  }
  return refused
}

// Edit an existing client in the same form as the registration (owner decision). The CPF never changes.
export async function updateCustomer(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const id = val(formData, 'client_id')
  if (!isId(id)) return go('erro:requisicao_invalida')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${id}`, code))
  const done = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/clientes/${id}`, code))
  const zip = val(formData, 'zip')
  if (zip && !normalizeCep(zip)) return back('erro:cep_invalido')

  const { error: identityError } = await supabase.rpc('update_client_identity', {
    p_client: id, p_full_name: val(formData, 'full_name'), p_phone: orNull(formData, 'phone'), p_email: orNull(formData, 'email'),
  })
  if (identityError) {
    const m = identityError.message ?? ''
    return back(/full_name_required/.test(m) ? 'erro:nome_invalido' : /invalid_phone/.test(m) ? 'erro:ficha_telefone' : /invalid_email/.test(m) ? 'erro:email_invalido' : classifyDbFeedback(identityError))
  }
  const { error: profileErr } = await supabase.rpc('update_client_profile', {
    p_client: id, p_birth_date: dateOrNull(formData, 'birth_date'), p_father_name: orNull(formData, 'father_name'), p_mother_name: orNull(formData, 'mother_name'),
    p_rg_number: orNull(formData, 'rg_number'), p_rg_issuer: orNull(formData, 'rg_issuer'), p_rg_state: orNull(formData, 'rg_state'),
    p_rg_issued_on: dateOrNull(formData, 'rg_issued_on'), p_gender: orNull(formData, 'gender'), p_marital_status: orNull(formData, 'marital_status'),
    p_birthplace_city: orNull(formData, 'birthplace_city'), p_birthplace_state: orNull(formData, 'birthplace_state'),
    p_whatsapp: formData.get('whatsapp_same') === 'on' ? orNull(formData, 'phone') : orNull(formData, 'whatsapp'),
  })
  if (profileErr) return back(profileError(profileErr.message ?? '') ?? classifyDbFeedback(profileErr))
  if (zip) {
    const failure = await persistAddress(supabase, organization.id, id, formData)
    if (failure) return back(failure)
  }
  const refused = await saveRows(supabase, id, false, formData)
  revalidatePath(`/app/clientes/${id}`)
  revalidatePath('/app/clientes')
  return refused ? back('erro:ficha_linhas_recusadas') : done('ok:cadastro_atualizado')
}
