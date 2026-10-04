import type { requireAppContext } from '@/lib/appContext'
import type { ClientExtra } from './contract-layout'

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']

const PROFILE_KEYS = ['birth_date', 'father_name', 'mother_name', 'rg_number', 'rg_issuer', 'rg_state', 'rg_issued_on', 'gender',
  'marital_status', 'birthplace_city', 'birthplace_state', 'whatsapp'] as const
type ProfileKey = (typeof PROFILE_KEYS)[number]

const PART_LABEL = { profile: 'dados pessoais', address: 'endereço', account: 'conta bancária', registration: 'matrícula' } as const

// Completes the client record with what an imported line brings, through the same RPCs and tables as the client form.
// Never erases: personal data fills only empty fields, the address only when the client has no primary one, an account
// or a registration only when the client does not have the same one yet. A failure here never undoes the contract;
// it comes back as a warning. Returns what was filled and the warnings.
export async function enrichClient(supabase: Supa, organizationId: string, clientId: string, extra: ClientExtra, agreementId: string | null) {
  const filled: string[] = []
  const warnings: string[] = []
  const fail = (part: keyof typeof PART_LABEL) => warnings.push(`Ficha do cliente: ${PART_LABEL[part]} não gravado(a)`)

  const typed = extra.profile
  if (PROFILE_KEYS.some(k => typed[k])) {
    const { data: current, error: readError } = await supabase.from('clients').select(PROFILE_KEYS.join(',')).eq('id', clientId).maybeSingle()
    if (readError || !current) fail('profile')
    else {
      const cur = current as unknown as Partial<Record<ProfileKey, string | null>>
      const merged = Object.fromEntries(PROFILE_KEYS.map(k => [k, cur[k] ?? typed[k] ?? null])) as Record<ProfileKey, string | null>
      if (PROFILE_KEYS.some(k => !cur[k] && typed[k])) {
        const { error } = await supabase.rpc('update_client_profile', {
          p_client: clientId, p_birth_date: merged.birth_date, p_father_name: merged.father_name, p_mother_name: merged.mother_name,
          p_rg_number: merged.rg_number, p_rg_issuer: merged.rg_issuer, p_rg_state: merged.rg_state, p_rg_issued_on: merged.rg_issued_on,
          p_gender: merged.gender, p_marital_status: merged.marital_status, p_birthplace_city: merged.birthplace_city,
          p_birthplace_state: merged.birthplace_state, p_whatsapp: merged.whatsapp,
        })
        if (error) fail('profile'); else filled.push(PART_LABEL.profile)
      }
    }
  }

  if (extra.address) {
    const { data: primary, error: readError } = await supabase.from('customer_addresses').select('id').eq('customer_id', clientId).eq('is_primary', true).limit(1).maybeSingle()
    if (readError) fail('address')
    else if (!primary) {
      const { error } = await supabase.from('customer_addresses').insert({ organization_id: organizationId, customer_id: clientId, is_primary: true, ...extra.address })
      if (error) fail('address'); else filled.push(PART_LABEL.address)
    }
  }

  if (extra.account) {
    const a = extra.account
    const [{ data: same }, { data: primary }] = await Promise.all([
      supabase.from('customer_bank_accounts').select('id').eq('customer_id', clientId).eq('bank_code', a.bank_code).eq('branch', a.branch).eq('account_number', a.account_number).limit(1).maybeSingle(),
      supabase.from('customer_bank_accounts').select('id').eq('customer_id', clientId).eq('is_primary', true).limit(1).maybeSingle(),
    ])
    if (!same) {
      const { error } = await supabase.rpc('add_client_bank_account', {
        p_client: clientId, p_bank_code: a.bank_code, p_bank_name: a.bank_name, p_branch: a.branch, p_account_number: a.account_number,
        p_account_digit: a.account_digit, p_account_type: a.account_type, p_primary: !primary,
      })
      if (error) fail('account'); else filled.push(PART_LABEL.account)
    }
  }

  if (extra.registration && agreementId) {
    const r = extra.registration
    const { data: same } = await supabase.from('client_registrations').select('id').eq('customer_id', clientId).eq('registration_number', r.number).limit(1).maybeSingle()
    if (!same) {
      const { error } = await supabase.rpc('save_client_registration', {
        p_client: clientId, p_registration: null, p_agreement: agreementId, p_agency_name: r.agency, p_registration_number: r.number,
        p_status: 'active', p_margin_amount: null, p_margin_as_of: null, p_portal_login: null, p_password: null, p_clear_password: false, p_notes: null,
      })
      if (error) fail('registration'); else filled.push(PART_LABEL.registration)
    }
  }
  return { filled, warnings }
}
