'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'
import { parseMoneyInput } from '@/lib/money-input'
import { parsePercentInput } from '@/lib/percent-input'

const go = (path: string, code: FeedbackCode): never => redirect(feedbackUrl(path, code))
const payoutError = (m: string): FeedbackCode | null =>
  /four_eyes_required/.test(m) ? 'erro:quatro_olhos'
  : /insufficient_balance/.test(m) ? 'erro:saldo_insuficiente'
  : /payout_open/.test(m) ? 'erro:repasse_aberto'
  : /invalid_amount/.test(m) ? 'erro:repasse_valor'
  : /description_required|invalid_installments|invalid_entry_kind|invalid_direction|invalid_period_end/.test(m) ? 'erro:repasse_dados'
  : /reference_required|invalid_paid_on/.test(m) ? 'erro:repasse_referencia'
  : /account_model_required/.test(m) ? 'erro:repasse_modelo'
  : /note_required/.test(m) ? 'erro:receita_motivo'
  : null
const fail = (path: string, error: { message?: string; code?: string }): never => go(path, payoutError(error.message ?? '') ?? classifyDbFeedback(error))
const back = (formData: FormData) => {
  const b = String(formData.get('back') ?? '/app/repasse')
  return /^\/app\/repasse(\/[0-9a-f-]{36})?$/.test(b) ? b : '/app/repasse'
}

export async function savePayoutSettings(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const path = '/app/configuracao/repasse'
  const model = String(formData.get('default_model') ?? ''), freq = String(formData.get('closing_frequency') ?? '')
  const limit = parsePercentInput(formData.get('debt_limit_pct'))
  if (!['closing', 'account'].includes(model) || !['weekly', 'biweekly', 'monthly'].includes(freq) || limit === null || limit === 'invalid') return go(path, 'erro:percentual_invalido')
  const { error } = await supabase.rpc('save_payout_settings', { p_org: organization.id, p_default_model: model, p_closing_frequency: freq, p_debt_limit_pct: limit })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:repasse_config_salva')
}

export async function openAccount(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const [kind, id] = String(formData.get('payee') ?? '').split(':')
  if (!['seller', 'member'].includes(kind) || !isUuid(id)) return go('/app/repasse', 'erro:requisicao_invalida')
  const { data, error } = await supabase.rpc('ensure_payout_account', { p_org: organization.id, p_seller: kind === 'seller' ? id : null, p_user: kind === 'member' ? id : null })
  if (error) return fail('/app/repasse', error)
  return go(`/app/repasse/${data}`, 'ok:conta_aberta')
}

export async function addEntry(formData: FormData) {
  const { supabase } = await requireAppContext()
  const account = String(formData.get('account_id') ?? '')
  const path = `/app/repasse/${account}`
  if (!isUuid(account)) return go('/app/repasse', 'erro:requisicao_invalida')
  const amount = parseMoneyInput(formData.get('amount'))
  if (amount === null || amount === 'invalid') return go(path, 'erro:repasse_valor')
  const installments = Number(String(formData.get('installments') ?? '1')) || 1
  const { error } = await supabase.rpc('add_payout_entry', {
    p_account: account, p_kind: String(formData.get('kind') ?? ''), p_amount: amount, p_direction: String(formData.get('direction') ?? '') || null,
    p_description: String(formData.get('description') ?? ''), p_effective_on: String(formData.get('effective_on') ?? '') || null, p_installments: installments,
  })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:lancamento_registrado')
}

export async function decideEntry(formData: FormData) {
  const { supabase } = await requireAppContext()
  const path = back(formData)
  const entry = String(formData.get('entry_id') ?? '')
  if (!isUuid(entry)) return go(path, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('decide_payout_entry', { p_entry: entry, p_approve: formData.get('decision') === 'approve', p_note: String(formData.get('note') ?? '') || null })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:lancamento_decidido')
}

export async function closePeriod(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const end = String(formData.get('period_end') ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(end)) return go('/app/repasse', 'erro:repasse_dados')
  const { error } = await supabase.rpc('close_payout_period', { p_org: organization.id, p_period_end: end })
  if (error) return fail('/app/repasse', error)
  revalidatePath('/app/repasse')
  return go('/app/repasse', 'ok:periodo_fechado')
}

export async function requestWithdrawal(formData: FormData) {
  const { supabase } = await requireAppContext()
  const account = String(formData.get('account_id') ?? '')
  const path = `/app/repasse/${account}`
  if (!isUuid(account)) return go('/app/repasse', 'erro:requisicao_invalida')
  const amount = parseMoneyInput(formData.get('amount'))
  if (amount === null || amount === 'invalid') return go(path, 'erro:repasse_valor')
  const { error } = await supabase.rpc('request_payout_withdrawal', { p_account: account, p_amount: amount, p_note: String(formData.get('note') ?? '') || null })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:saque_solicitado')
}

export async function decidePayout(formData: FormData) {
  const { supabase } = await requireAppContext()
  const path = back(formData)
  const payout = String(formData.get('payout_id') ?? '')
  if (!isUuid(payout)) return go(path, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('decide_payout', { p_payout: payout, p_approve: formData.get('decision') === 'approve', p_note: String(formData.get('note') ?? '') || null })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:repasse_decidido')
}

export async function markPaid(formData: FormData) {
  const { supabase } = await requireAppContext()
  const path = back(formData)
  const payout = String(formData.get('payout_id') ?? '')
  if (!isUuid(payout)) return go(path, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('mark_payout_paid', { p_payout: payout, p_paid_on: String(formData.get('paid_on') ?? '') || null, p_reference: String(formData.get('reference') ?? '') })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:repasse_pago')
}

export async function setAccountModel(formData: FormData) {
  const { supabase } = await requireAppContext()
  const account = String(formData.get('account_id') ?? '')
  const path = `/app/repasse/${account}`
  const model = String(formData.get('model') ?? '')
  if (!isUuid(account) || !['', 'closing', 'account'].includes(model)) return go('/app/repasse', 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('set_payout_account_model', { p_account: account, p_model: model || null })
  if (error) return fail(path, error)
  revalidatePath(path)
  return go(path, 'ok:modelo_alterado')
}
