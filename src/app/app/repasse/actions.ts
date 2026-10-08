'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { assignBankAccount, bankAccountOf } from '@/lib/finBankAccounts'
import { isUuid } from '@/lib/team'
import { parseMoneyInput } from '@/lib/money-input'
import { parsePercentInput } from '@/lib/percent-input'

const go = (path: string, code: FeedbackCode): never => redirect(feedbackUrl(path, code))
const payoutError = (m: string): FeedbackCode | null =>
  /four_eyes_required/.test(m) ? 'erro:quatro_olhos'
  : /nothing_to_pay/.test(m) ? 'erro:repasse_nada_a_pagar'
  : /cannot_pay_yourself/.test(m) ? 'erro:repasse_proprio'
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
  const freq = String(formData.get('frequency') ?? '')
  if (!['daily', 'weekly', 'biweekly', 'monthly'].includes(freq)) return go('/app/repasse', 'erro:repasse_dados')
  // Part C3: one frequency at a time (each seller has theirs).
  const { error } = await supabase.rpc('close_payout_period', { p_org: organization.id, p_period_end: end, p_frequency: freq })
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
  const { supabase, organization } = await requireAppContext()
  const path = back(formData)
  const payout = String(formData.get('payout_id') ?? '')
  if (!isUuid(payout)) return go(path, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('mark_payout_paid', { p_payout: payout, p_paid_on: String(formData.get('paid_on') ?? '') || null, p_reference: String(formData.get('reference') ?? '') })
  if (error) return fail(path, error)
  await assignBankAccount(supabase, organization.id, 'payout', [payout], bankAccountOf(formData))
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

// Pay the account in one action (owner decision 29/09/2026, ADR-0048): the database computes the amount exactly as a
// period closing (or the available balance), records who paid, when and the proof, and moves the money as before.
export async function payNow(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const account = String(formData.get('account_id') ?? '')
  const path = `/app/repasse/${account}`
  if (!isUuid(account)) return go('/app/repasse', 'erro:requisicao_invalida')
  const paidOn = String(formData.get('paid_on') ?? '')
  const reference = String(formData.get('reference') ?? '').trim()
  // Proof is optional (owner, 29/09/2026): blank is recorded as "Sem comprovante informado" by the database.
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn) || reference.length > 120) return go(path, 'erro:repasse_referencia')
  const { data: payout, error } = await supabase.rpc('pay_account_now', { p_account: account, p_paid_on: paidOn, p_reference: reference })
  if (error) return fail(path, error)
  // The company account the money left from (07/10/2026).
  await assignBankAccount(supabase, organization.id, 'payout', isUuid(String(payout ?? '')) ? [String(payout)] : [], bankAccountOf(formData))
  revalidatePath(path); revalidatePath('/app/repasse'); revalidatePath('/app/financeiro/empresa')
  return go(path, 'ok:repasse_pago_agora')
}

export type PayBatchResult = { error?: string; ok: number; total: string; failed: { account: string; name: string; reason: string }[] }
const PAY_REASON: [RegExp, string][] = [
  [/amount_changed/, 'o valor mudou desde que a lista foi aberta: atualize a página e confira antes de confirmar'],
  [/nothing_to_pay/, 'não há nada a pagar'],
  [/cannot_pay_yourself/, 'ninguém registra o pagamento da própria conta'],
  [/not_authorized/, 'sem permissão para pagar'],
]

// Confirms the payments made in the bank, several accounts at once (owner request 06/10/2026). Each account is paid
// exactly like "Pagar agora", and only when its amount is still the one on screen (the one paid by PIX or TED).
export async function payBatch(formData: FormData): Promise<PayBatchResult> {
  const { supabase, organization } = await requireAppContext()
  const paidOn = String(formData.get('paid_on') ?? '')
  const reference = String(formData.get('reference') ?? '').trim()
  const empty = { ok: 0, total: '0.00', failed: [] }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn)) return { ...empty, error: 'Informe a data do pagamento.' }
  if (reference.length > 120) return { ...empty, error: 'Comprovante com no máximo 120 caracteres.' }
  const chosen = [...new Set(formData.getAll('account').map(String))].filter(isUuid)
  if (!chosen.length) return { ...empty, error: 'Marque pelo menos um vendedor.' }
  if (chosen.length > 300) return { ...empty, error: 'Marque no máximo 300 por vez.' }
  const result: PayBatchResult = { ok: 0, total: '0.00', failed: [] }
  let cents = BigInt(0)
  const paid: string[] = []
  for (const account of chosen) {
    const expected = String(formData.get(`amount_${account}`) ?? '')
    const name = String(formData.get(`name_${account}`) ?? 'Conta')
    if (!/^\d{1,12}\.\d{2}$/.test(expected)) { result.failed.push({ account, name, reason: 'valor inválido' }); continue }
    const { data: payout, error } = await supabase.rpc('pay_account_now_checked', { p_account: account, p_paid_on: paidOn, p_reference: reference, p_expected: expected })
    if (!error && isUuid(String(payout ?? ''))) paid.push(String(payout))
    if (error) { result.failed.push({ account, name, reason: PAY_REASON.find(([re]) => re.test(error.message ?? ''))?.[1] ?? 'não foi possível registrar' }); continue }
    result.ok++
    cents += BigInt(expected.replace('.', ''))
  }
  result.total = `${cents / BigInt(100)}.${String(cents % BigInt(100)).padStart(2, '0')}`
  // The company account the money left from (07/10/2026).
  if (!(await assignBankAccount(supabase, organization.id, 'payout', paid, bankAccountOf(formData))))
    result.error = 'Pagamentos registrados, mas a conta bancária não foi gravada: informe-a em Financeiro.'
  revalidatePath('/app/repasse'); revalidatePath('/app/financeiro/empresa')
  return result
}
