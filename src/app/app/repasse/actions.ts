'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { bankAccountOf } from '@/lib/finBankAccounts'
import { expectedAmount, sumAmounts } from '@/lib/payout/pay-safety'
import { isUuid } from '@/lib/team'
import type { Breakdown } from '@/lib/payout/batches'
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
  : /amount_changed/.test(m) ? 'erro:repasse_valor_mudou'
  : /fin_bank_account_invalid/.test(m) ? 'erro:fin_conta_bancaria'
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

// "Desfazer pagamento" (owner request 13/10/2026): a payment registered but not made in the bank. Administrators only;
// the database reverses it with the reason, returns the amount to the balance and cancels the bank outflow.
export async function reversePayout(formData: FormData) {
  const { supabase } = await requireAppContext()
  const path = back(formData)
  const payout = String(formData.get('payout_id') ?? '')
  const reason = String(formData.get('reason') ?? '').trim()
  if (!isUuid(payout)) return go(path, 'erro:requisicao_invalida')
  if (reason.length < 3 || reason.length > 300) return go(path, 'erro:repasse_desfazer_motivo')
  const { error } = await supabase.rpc('reverse_payout', { p_payout: payout, p_reason: reason })
  if (error) {
    const m = error.message ?? ''
    if (/later_payout_exists/.test(m)) return go(path, 'erro:repasse_desfazer_posterior')
    if (/payout_reconciled/.test(m)) return go(path, 'erro:repasse_desfazer_conciliado')
    if (/payout_not_paid/.test(m)) return go(path, 'erro:repasse_desfazer_nao_pago')
    return fail(path, error)
  }
  revalidatePath(path); revalidatePath('/app/repasse'); revalidatePath('/app/financeiro/empresa')
  return go(path, 'ok:repasse_desfeito')
}

// The payment and the company bank account it left from in one transaction (audit 06/11/2026): both or neither.
export async function markPaid(formData: FormData) {
  const { supabase } = await requireAppContext()
  const path = back(formData)
  const payout = String(formData.get('payout_id') ?? '')
  if (!isUuid(payout)) return go(path, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('mark_payout_paid_with_bank', {
    p_payout: payout, p_paid_on: String(formData.get('paid_on') ?? '') || null, p_reference: String(formData.get('reference') ?? ''), p_bank_account: bankAccountOf(formData),
  })
  if (error) return fail(path, error)
  revalidatePath(path); revalidatePath('/app/financeiro/empresa')
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

// Pay the account in one action (owner decision 29/09/2026, ADR-0048). Audit 06/11/2026: the screen shows the exact
// amount the database pays (payout_pay_now_amount) and sends it back; the database refuses when it is no longer that
// amount (amount_changed) and records the company bank account in the same transaction.
export async function payNow(formData: FormData) {
  const { supabase } = await requireAppContext()
  const account = String(formData.get('account_id') ?? '')
  const path = `/app/repasse/${account}`
  if (!isUuid(account)) return go('/app/repasse', 'erro:requisicao_invalida')
  const paidOn = String(formData.get('paid_on') ?? '')
  const reference = String(formData.get('reference') ?? '').trim()
  const expected = expectedAmount(formData.get('expected'))
  if (!expected) return go(path, 'erro:repasse_valor_mudou')
  // Proof is optional (owner, 29/09/2026): blank is recorded as "Sem comprovante informado" by the database.
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn) || reference.length > 120) return go(path, 'erro:repasse_referencia')
  const { error } = await supabase.rpc('pay_account_confirmed', { p_account: account, p_paid_on: paidOn, p_reference: reference, p_expected: expected, p_bank_account: bankAccountOf(formData) })
  if (error) return fail(path, error)
  revalidatePath(path); revalidatePath('/app/repasse'); revalidatePath('/app/financeiro/empresa')
  return go(path, 'ok:repasse_pago_agora')
}

export type PayBatchResult = { error?: string; ok: number; total: string; failed: { account: string; name: string; reason: string }[]; batchId?: string }
const PAY_REASON: [RegExp, string][] = [
  [/amount_changed/, 'o valor mudou desde que a lista foi aberta: atualize a página e confira'],
  [/nothing_to_pay/, 'não há nada a pagar'],
  [/cannot_pay_yourself/, 'ninguém registra o pagamento da própria conta'],
  [/not_authorized/, 'sem permissão para pagar'],
]

// Confirms the payments made in the bank, several accounts at once (owner request 06/10/2026). Audit 06/11/2026: one
// database call, all or nothing (pay_payout_batch): every amount must still be the one on screen, all are paid in one
// batch with the company bank account, or nothing is recorded and the screen says who blocked it.
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
  const nameOf = (account: string) => String(formData.get(`name_${account}`) ?? '') || undefined
  const lines = chosen.map(account => ({ account, expected: expectedAmount(formData.get(`amount_${account}`)) }))
  const invalid = lines.filter(l => !l.expected)
  if (invalid.length) return { ...empty, error: 'Nada foi registrado: valor inválido na lista.', failed: invalid.map(l => ({ account: l.account, name: nameOf(l.account) ?? 'Conta', reason: 'valor inválido' })) }
  const { data, error } = await supabase.rpc('pay_payout_batch', { p_org: organization.id, p_paid_on: paidOn, p_reference: reference, p_bank_account: bankAccountOf(formData), p_lines: lines })
  if (error) {
    const m = error.message ?? ''
    const reason = PAY_REASON.find(([re]) => re.test(m))?.[1]
    const named = String(error.details ?? '').split(',').map(s => s.trim()).filter(isUuid)
    const failed = reason ? named.map(account => ({ account, name: nameOf(account) ?? 'Conta', reason })) : []
    const text = /fin_bank_account_invalid/.test(m) ? ': a conta que pagou é inválida ou está desativada.'
      : /invalid_paid_on/.test(m) ? ': a data do pagamento deve ser hoje ou antes.'
      : failed.length ? '. Confira:'
      : reason ? `: ${reason}.` : '. Tente de novo.'
    return { ...empty, failed, error: `Nada foi registrado${text}` }
  }
  const r = (data ?? {}) as { batch_id?: string; paid?: number; total?: string }
  revalidatePath('/app/repasse'); revalidatePath('/app/repasse/lotes'); revalidatePath('/app/financeiro/empresa')
  return { ok: Number(r.paid ?? 0), total: sumAmounts([r.total]), failed: [], batchId: r.batch_id }
}

// "ver contratos" in "Pagar vendedores" (owner, 06/11/2026): what paying this account now would pay, before paying.
// Read only; the database checks who may see it (repasse.approve, never the own account).
export async function loadPayPreview(account: string): Promise<{ data?: Breakdown & { total: string }; error?: string }> {
  if (!isUuid(account)) return { error: 'Conta inválida.' }
  const { supabase } = await requireAppContext()
  const { data, error } = await supabase.rpc('payout_pay_preview', { p_account: account })
  if (error || !data) return { error: 'Não foi possível carregar os contratos.' }
  return { data: data as Breakdown & { total: string } }
}

// "Desfazer lote": every payment of the batch still paid, at once (administrators; the database checks).
export async function reverseBatch(formData: FormData) {
  const { supabase } = await requireAppContext()
  const batch = String(formData.get('batch_id') ?? '')
  const path = isUuid(batch) ? `/app/repasse/lotes/${batch}` : '/app/repasse/lotes'
  const reason = String(formData.get('reason') ?? '').trim()
  if (!isUuid(batch)) return go('/app/repasse/lotes', 'erro:requisicao_invalida')
  if (reason.length < 3 || reason.length > 300) return go(path, 'erro:repasse_desfazer_motivo')
  const { error } = await supabase.rpc('reverse_payout_batch', { p_batch: batch, p_reason: reason })
  if (error) {
    const m = error.message ?? ''
    if (/later_payout_exists/.test(m)) return go(path, 'erro:repasse_desfazer_posterior')
    if (/payout_reconciled/.test(m)) return go(path, 'erro:repasse_desfazer_conciliado')
    if (/batch_already_reversed|batch_nothing_to_reverse/.test(m)) return go(path, 'erro:lote_ja_desfeito')
    return fail(path, error)
  }
  revalidatePath(path); revalidatePath('/app/repasse/lotes'); revalidatePath('/app/repasse'); revalidatePath('/app/financeiro/empresa')
  return go(path, 'ok:lote_desfeito')
}
