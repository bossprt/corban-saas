'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { isPlanModule } from '@/lib/access'
import { digitsOnly, isValidCnpj, sameOrganizationName } from '@/lib/platform'
import { PASSWORD_MAX, PASSWORD_MIN, passwordRefusal, TEAM_ERROR_MESSAGES } from '@/lib/team'

const clean = (v: FormDataEntryValue | null) => String(v ?? '').trim()
const code = (v: string) => v.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40)
const go = (kind: 'ok'|'erro', msg: string): never => {
  revalidatePath('/platform')
  redirect(`/platform?${kind}=${encodeURIComponent(msg)}`)
}
async function gate() {
  const g = await requirePlatformAdmin()
  if (!g.ok) redirect('/login')
  return g
}

export async function addDocumentType(f: FormData) {
  await gate()
  const name=clean(f.get('name'))
  if(!name) go('erro','Informe o tipo de documento.')

  const admin=createAdminClient()
  const base=code(name) || 'DOCUMENTO'
  let generated=base
  let suffix=2

  while (true) {
    const {data,error}=await admin.from('document_types').select('id').eq('code',generated).maybeSingle()
    if(error) go('erro','Não foi possível validar o identificador do documento.')
    if(!data) break
    const tail=`_${suffix++}`
    generated=`${base.slice(0, Math.max(1, 40-tail.length))}${tail}`
  }

  const {error}=await admin.from('document_types').insert({code:generated,name,is_active:true})
  if(error) go('erro','Não foi possível cadastrar o tipo de documento.')
  go('ok','Tipo de documento cadastrado. O identificador técnico foi gerado automaticamente.')
}

// Switches one module for one company (plan limits). Platform administrators only; every change is audited.
export async function setOrganizationModule(f: FormData) {
  const g = await gate()
  const org = clean(f.get('organization_id'))
  const moduleKey = clean(f.get('module_key'))
  const enabled = clean(f.get('enabled')) === 'true'
  if (!/^[0-9a-f-]{36}$/i.test(org) || !isPlanModule(moduleKey)) go('erro', 'Dados inválidos.')
  const admin = createAdminClient()
  const { error } = await admin.from('organization_modules')
    .upsert({ organization_id: org, module_key: moduleKey, enabled, updated_by: g.userId, updated_at: new Date().toISOString() }, { onConflict: 'organization_id,module_key' })
  if (error) go('erro', 'Não foi possível alterar o módulo.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, organization_id: org, action: 'organization_module.set', metadata: { module_key: moduleKey, enabled } })
  go('ok', `Módulo ${enabled ? 'ligado' : 'desligado'}.`)
}

// New client company with its first administrator (owner request 07/10/2026): the platform administrator types the
// company, the administrator's e-mail and a password (never e-mailed, never stored here). The administrator then creates
// the company's own team and sellers. The login is created confirmed; the database creates the company with its
// defaults, makes the person its administrator and audits it (bootstrap_organization_admin). If that fails, the new
// login is removed so no orphan identity stays. An e-mail that already has a login is refused: one login, one company.
export async function createCompanyWithAdmin(f: FormData) {
  const g = await gate()
  const name = clean(f.get('organization_name')).replace(/\s+/g, ' ')
  const document = digitsOnly(clean(f.get('organization_document')))
  const fullName = clean(f.get('full_name')).replace(/\s+/g, ' ')
  const email = clean(f.get('email')).toLowerCase()
  const password = String(f.get('password') ?? '')
  const mustChange = f.get('must_change') === 'on'
  if (name.length < 3 || name.length > 200) go('erro', 'Informe o nome da empresa (3 a 200 caracteres).')
  if (!isValidCnpj(document)) go('erro', 'CNPJ inválido.')
  if (fullName.length < 3 || fullName.length > 160) go('erro', 'Informe o nome do administrador.')
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) go('erro', 'E-mail do administrador inválido.')
  if (password.length < PASSWORD_MIN || password.length > PASSWORD_MAX || password !== String(f.get('password_confirm') ?? ''))
    go('erro', `Senha inválida: use no mínimo ${PASSWORD_MIN} caracteres e repita igual no segundo campo.`)

  const admin = createAdminClient()
  const { data: existing, error: listError } = await admin.from('organizations').select('name,document')
  if (listError) go('erro', 'Não foi possível conferir as empresas existentes.')
  if ((existing ?? []).some(o => digitsOnly(String(o.document ?? '')) === document)) go('erro', 'Já existe uma empresa com este CNPJ.')
  if (f.get('confirm_similar') !== 'on' && (existing ?? []).some(o => sameOrganizationName(String(o.name ?? ''), name)))
    go('erro', 'Já existe uma empresa com nome parecido. Confira e marque "o nome parecido está certo" para continuar.')

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email, password, email_confirm: true, app_metadata: { must_change_password: mustChange }, user_metadata: { full_name: fullName },
  })
  if (createError || !created.user) {
    const weak = passwordRefusal(createError)
    if (weak) go('erro', TEAM_ERROR_MESSAGES[weak])
    if (/already|registered|exists/i.test(createError?.message ?? '')) go('erro', 'Este e-mail já tem acesso ao Corban. Use outro e-mail para o administrador da empresa nova.')
    go('erro', 'Não foi possível criar o login do administrador.')
  }
  const userId = created.user!.id
  const { error: bootstrapError } = await admin.rpc('bootstrap_organization_admin', {
    p_platform_actor_user_id: g.userId, p_user_id: userId, p_organization_name: name, p_organization_document: document, p_plan_type: 'founder',
  })
  if (bootstrapError) {
    await admin.auth.admin.deleteUser(userId)
    go('erro', 'Não foi possível criar a empresa. Nada foi gravado.')
  }
  // No e-mail or name of the person in the address bar (personal data never goes in a URL).
  go('ok', `${name} criada. O administrador entra com o e-mail e a senha informados${mustChange ? ' e escolhe uma nova senha no primeiro acesso' : ''}.`)
}

// Publishes a version of the terms of use (08/10/2026): the text approved by the lawyer, pasted here. From then on
// every company must accept it before using the system. A published text is never changed: a correction is a new
// version. The SHA-256 of the text is stored so each acceptance proves which text was accepted.
export async function publishTermsVersion(f: FormData) {
  const g = await gate()
  const version = clean(f.get('version'))
  const title = clean(f.get('title'))
  const body = String(f.get('body') ?? '').replace(/\r\n/g, '\n').trim()
  if (version.length < 1 || version.length > 40) go('erro', 'Informe a versão dos termos (até 40 caracteres).')
  if (title.length < 3 || title.length > 200) go('erro', 'Informe o título dos termos.')
  if (body.length < 20 || body.length > 200000) go('erro', 'Cole o texto completo dos termos.')
  if (f.get('confirm') !== 'on') go('erro', 'Confirme que o texto foi aprovado e que todas as empresas terão de aceitá-lo.')
  const { createHash } = await import('node:crypto')
  const sha = createHash('sha256').update(body, 'utf8').digest('hex')
  const admin = createAdminClient()
  const { data, error } = await admin.from('terms_versions').insert({ version, title, body, body_sha256: sha, published_by: g.userId }).select('id').single()
  if (error || !data) go('erro', /duplicate|unique/i.test(error?.message ?? '') ? 'Já existe uma versão com esse nome.' : 'Não foi possível publicar os termos.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, action: 'terms_version.publish', metadata: { version, terms_version_id: data!.id, body_sha256: sha } })
  go('ok', `Termos versão ${version} publicados. Cada empresa aceita no próximo acesso do administrador.`)
}

// Answer an improvement request (status and the answer the company sees); the database checks the platform administrator.
export async function answerImprovement(f: FormData) {
  const g = await gate()
  const id = clean(f.get('request_id')), status = clean(f.get('status')), response = clean(f.get('response'))
  if (!/^[0-9a-f-]{36}$/.test(id) || !['received', 'analyzing', 'approved', 'declined', 'delivered'].includes(status)) go('erro', 'Solicitação inválida.')
  if (status === 'declined' && response.length < 3) go('erro', 'Para "Não será feita", escreva o motivo na resposta.')
  const { error } = await createAdminClient().rpc('platform_answer_improvement_request', { p_request: id, p_status: status, p_response: response || null, p_actor: g.userId })
  if (error) go('erro', 'Não foi possível salvar a resposta.')
  go('ok', 'Resposta salva. A empresa vê na tela Sugerir melhoria.')
}

// Monthly fee (03/11/2026): the Pix receiver, each company's subscription, and the payments confirmed by hand. The
// database checks the rules (two decimals, paid once, reversal with a reason, nothing changed or deleted); every
// change is audited. The receiver's key is never written to the audit or to a log.
const BILLING_ERRORS: Record<string, string> = {
  billing_invalid_amount: 'Valor inválido: use até duas casas decimais.',
  billing_charge_already_paid: 'Esta mensalidade já está paga.',
  billing_charge_not_paid: 'Só se estorna uma mensalidade paga.',
  billing_reversal_note_required: 'Escreva o motivo do estorno.',
  billing_invalid_paid_on: 'Data de recebimento inválida (não pode ser futura).',
  billing_charge_not_found: 'Mensalidade não encontrada.',
}
const billingFail = (e: { message?: string }, fallback: string): never => go('erro', Object.entries(BILLING_ERRORS).find(([k]) => (e.message ?? '').includes(k))?.[1] ?? fallback)
const isUuid = (v: string) => /^[0-9a-f-]{36}$/i.test(v)
const isDay = (v: string) => /^\d{4}-\d{2}-\d{2}$/.test(v)

export async function saveBillingSettings(f: FormData) {
  const g = await gate()
  const key = clean(f.get('pix_key')), type = clean(f.get('pix_key_type')), name = clean(f.get('merchant_name')), city = clean(f.get('merchant_city'))
  if (!key || key.length > 77 || !['cpf','cnpj','email','phone','random'].includes(type) || !name || name.length > 25 || !city || city.length > 15) go('erro', 'Confira chave, tipo, nome (até 25) e cidade (até 15).')
  const pixKey = type === 'cpf' || type === 'cnpj' ? digitsOnly(key) : key
  const admin = createAdminClient()
  const { error } = await admin.rpc('platform_set_billing_settings', { p_actor: g.userId, p_key: pixKey, p_key_type: type, p_name: name, p_city: city })
  if (error) billingFail(error, 'Não foi possível salvar o recebedor.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, action: 'billing.settings.set', metadata: { pix_key_type: type } })
  go('ok', 'Recebedor do Pix salvo.')
}

export async function saveSubscription(f: FormData) {
  const g = await gate()
  const org = clean(f.get('organization_id')), amount = clean(f.get('amount')).replace(/\./g, '').replace(',', '.')
  const dueDay = Number(clean(f.get('due_day'))), grace = Number(clean(f.get('grace_days'))), starts = clean(f.get('starts_on'))
  if (!isUuid(org) || !/^\d{1,8}(\.\d{1,2})?$/.test(amount) || !Number.isInteger(dueDay) || dueDay < 1 || dueDay > 28 || !Number.isInteger(grace) || grace < 0 || grace > 30 || !/^\d{4}-\d{2}$/.test(starts)) go('erro', 'Confira valor, dia (1 a 28), carência (0 a 30) e mês de início.')
  const admin = createAdminClient()
  // amount travels as text, the database turns it into numeric(14,2)
  const { error } = await admin.rpc('platform_set_subscription', { p_actor: g.userId, p_org: org, p_amount: amount, p_due_day: dueDay, p_grace_days: grace, p_starts_on: `${starts}-01`, p_active: f.get('is_active') === 'on' })
  if (error) billingFail(error, 'Não foi possível salvar a assinatura.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, organization_id: org, action: 'billing.subscription.set', metadata: { amount, due_day: dueDay, grace_days: grace, starts_on: starts, active: f.get('is_active') === 'on' } })
  go('ok', 'Assinatura salva.')
}

export async function markChargePaid(f: FormData) {
  const g = await gate()
  const charge = clean(f.get('charge_id')), paidOn = clean(f.get('paid_on')), org = clean(f.get('organization_id'))
  if (!isUuid(charge) || !isDay(paidOn)) go('erro', 'Dados inválidos.')
  const admin = createAdminClient()
  const { error } = await admin.rpc('platform_mark_charge_paid', { p_actor: g.userId, p_charge: charge, p_paid_on: paidOn })
  if (error) billingFail(error, 'Não foi possível confirmar o recebimento.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, organization_id: isUuid(org) ? org : null, action: 'billing.charge.paid', metadata: { charge_id: charge, paid_on: paidOn } })
  go('ok', 'Recebimento confirmado. O acesso da empresa está liberado.')
}

export async function reverseCharge(f: FormData) {
  const g = await gate()
  const charge = clean(f.get('charge_id')), note = clean(f.get('note')), org = clean(f.get('organization_id'))
  if (!isUuid(charge)) go('erro', 'Dados inválidos.')
  const admin = createAdminClient()
  const { error } = await admin.rpc('platform_reverse_charge', { p_actor: g.userId, p_charge: charge, p_note: note })
  if (error) billingFail(error, 'Não foi possível estornar.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, organization_id: isUuid(org) ? org : null, action: 'billing.charge.reversed', metadata: { charge_id: charge } })
  go('ok', 'Recebimento estornado.')
}
