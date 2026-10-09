'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { normalizePct } from '@/lib/commission/groupRule'
import { isUuid } from '@/lib/team'

// Quick changes from the Contratos list (owner request 08/10/2026): each one goes through the same database call as the
// contract page (update_contract, set_contract_ade, set_payout_override, add_contract_note, calculate_contract_commission)
// and returns to the list where it was, with the filters kept. "back" is accepted only as a Contratos address.
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const listOf = (f: FormData) => {
  const v = text(f, 'back')
  return /^\/app\/contratos(\?[\w=&%:.+-]*)?$/.test(v) ? v : '/app/contratos'
}
const go = (f: FormData, code: FeedbackCode, keepOpen?: { id: string; acao: string }): never => {
  revalidatePath('/app/contratos')
  let to = listOf(f)
  if (keepOpen) to += `${to.includes('?') ? '&' : '?'}contrato=${keepOpen.id}&acao=${keepOpen.acao}`
  return redirect(feedbackUrl(to, code))
}
const dbCode = (m: string, fallback: FeedbackCode): FeedbackCode =>
  /contract_payout_received/.test(m) ? 'erro:contrato_recebido'
    : /contract_closed/.test(m) ? 'erro:contrato_encerrado'
    : /reason_required/.test(m) ? 'erro:contrato_motivo'
    : /override_exceeds_received/.test(m) ? 'erro:repasse_excede'
    : /invalid_override/.test(m) ? 'erro:repasse_invalido'
    : /commission_not_calculated/.test(m) ? 'erro:repasse_sem_calculo'
    : /seller_not_found/.test(m) ? 'erro:contrato_vendedor'
    : /invalid_amount/.test(m) ? 'erro:valor_invalido'
    : /invalid_term/.test(m) ? 'erro:prazo_invalido'
    : /invalid_paid_on/.test(m) ? 'erro:pago_data'
    : /ade_taken/.test(m) ? 'erro:ade_repetida'
    : /invalid_ade/.test(m) ? 'erro:ade_invalida'
    : /condition_not_found/.test(m) ? 'erro:comissao_sem_condicao'
    : /condition_ambiguous/.test(m) ? 'erro:comissao_ambigua'
    : /calculation_base_missing/.test(m) ? 'erro:comissao_sem_base'
    : /seller_without_group/.test(m) ? 'erro:comissao_vendedor_sem_grupo'
    : /group_rule_missing/.test(m) ? 'erro:comissao_grupo_sem_regra'
    : /proposal_without_seller/.test(m) ? 'erro:comissao_sem_vendedor'
    : /payout_exceeds_received/.test(m) ? 'erro:comissao_excede'
    : /not_authorized/.test(m) ? 'erro:sem_permissao'
    : fallback

export async function quickSeller(f: FormData) {
  const id = text(f, 'proposal_id'), seller = text(f, 'seller_id')
  if (!isUuid(id) || (seller && !isUuid(seller))) return go(f, 'erro:requisicao_invalida')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('update_contract', { p_proposal: id, p_data: { seller_id: seller }, p_reason: text(f, 'reason') || null })
  if (error) return go(f, dbCode(error.message ?? '', classifyDbFeedback(error)), { id, acao: 'vendedor' })
  return go(f, 'ok:contrato_atualizado')
}

export async function quickData(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return go(f, 'erro:requisicao_invalida')
  const money = (k: string) => parseMoneyInput(f.get(k))
  const requested = money('requested_amount'), released = money('released_amount'), installment = money('installment_amount')
  if (requested === 'invalid' || released === 'invalid' || installment === 'invalid' || (!requested && !released)) return go(f, 'erro:valor_invalido', { id, acao: 'dados' })
  const term = text(f, 'term')
  if (term && !/^\d{1,3}$/.test(term)) return go(f, 'erro:prazo_invalido', { id, acao: 'dados' })
  const paidOn = text(f, 'paid_to_client_on')
  if (paidOn && !/^\d{4}-\d{2}-\d{2}$/.test(paidOn)) return go(f, 'erro:pago_data', { id, acao: 'dados' })
  const data: Record<string, string> = { requested_amount: requested ?? '', released_amount: released ?? '', installment_amount: installment ?? '', term }
  if (paidOn) data.paid_to_client_on = paidOn
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('update_contract', { p_proposal: id, p_data: data, p_reason: text(f, 'reason') || null })
  if (error) return go(f, dbCode(error.message ?? '', classifyDbFeedback(error)), { id, acao: 'dados' })
  return go(f, 'ok:contrato_atualizado')
}

export async function quickAde(f: FormData) {
  const id = text(f, 'proposal_id'), ade = text(f, 'ade')
  if (!isUuid(id)) return go(f, 'erro:requisicao_invalida')
  if (!/^[0-9A-Za-z./-]{1,40}$/.test(ade)) return go(f, 'erro:ade_invalida', { id, acao: 'ade' })
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('set_contract_ade', { p_proposal: id, p_ade: ade, p_reason: text(f, 'reason') || null })
  if (error) return go(f, dbCode(error.message ?? '', classifyDbFeedback(error)), { id, acao: 'ade' })
  return go(f, 'ok:ade_alterada')
}

// What the seller gets ("2,5" = % of the base, "R$ 25,00" = fixed), or back to the rule. Administrador only (database).
export async function quickPayout(f: FormData) {
  const id = text(f, 'proposal_id'), component = text(f, 'component'), clear = text(f, 'clear') === '1', reason = text(f, 'reason')
  if (!isUuid(id) || !/^[a-z0-9_]{1,40}$/.test(component)) return go(f, 'erro:requisicao_invalida')
  if (reason.length < 3) return go(f, 'erro:repasse_motivo', { id, acao: 'comissao' })
  let kind: string | null = null, value: string | null = null
  if (!clear) {
    kind = text(f, 'kind') === 'fixed_brl' ? 'fixed_brl' : 'percentage'
    const raw = text(f, 'value')
    const parsed = kind === 'fixed_brl' ? parseMoneyInput(raw) : normalizePct(raw.replace(/%$/, ''))
    if (!parsed || parsed === 'invalid') return go(f, 'erro:repasse_invalido', { id, acao: 'comissao' })
    value = parsed
  }
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('set_payout_override', { p_proposal: id, p_component: component, p_kind: kind, p_value: value, p_reason: reason })
  if (error) return go(f, dbCode(error.message ?? '', classifyDbFeedback(error)), { id, acao: 'comissao' })
  return go(f, clear ? 'ok:repasse_regra' : 'ok:repasse_alterado')
}

export async function quickNote(f: FormData) {
  const id = text(f, 'proposal_id'), note = text(f, 'note')
  if (!isUuid(id)) return go(f, 'erro:requisicao_invalida')
  if (!note || note.length > 2000) return go(f, 'erro:observacao_invalida', { id, acao: 'observacoes' })
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('add_contract_note', { p_proposal: id, p_text: note })
  if (error) return go(f, classifyDbFeedback(error), { id, acao: 'observacoes' })
  return go(f, 'ok:observacao_salva', { id, acao: 'observacoes' })
}

// Calculate (or recalculate) the commission; with a table line chosen when the table has more than one for the contract.
export async function quickCalc(f: FormData) {
  const id = text(f, 'proposal_id'), condition = text(f, 'condition_id')
  if (!isUuid(id) || (condition && !isUuid(condition))) return go(f, 'erro:requisicao_invalida')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('calculate_contract_commission', { p_proposal_id: id, p_condition_id: condition || null })
  if (error) return go(f, dbCode(error.message ?? '', classifyDbFeedback(error)), { id, acao: 'calcular' })
  return go(f, 'ok:comissao_calculada')
}

export type BulkSellerResult = { error?: string; ok: number; failed: { id: string; label: string; reason: string }[] }
const REASON: [RegExp, string][] = [
  [/contract_payout_received/, 'o vendedor já recebeu a comissão deste contrato'],
  [/contract_closed/, 'contrato recusado ou cancelado'],
  [/reason_required/, 'contrato pago: informe o motivo'],
  [/override_exceeds_received/, 'o repasse alterado ficaria maior que a comissão recebida'],
  [/seller_not_found/, 'vendedor inativo ou não encontrado'],
  [/not_authorized/, 'sem permissão para este contrato'],
]

// The seller of several marked contracts at once; each contract is changed (and recalculated) on its own.
export async function bulkSeller(f: FormData): Promise<BulkSellerResult> {
  const { supabase } = await requireAppContext()
  const seller = text(f, 'seller_id'), reason = text(f, 'reason')
  if (!isUuid(seller)) return { error: 'Escolha o vendedor.', ok: 0, failed: [] }
  const ids = [...new Set(f.getAll('ids').map(String))].filter(isUuid)
  if (!ids.length) return { error: 'Marque pelo menos um contrato.', ok: 0, failed: [] }
  if (ids.length > 300) return { error: 'Marque no máximo 300 contratos por vez.', ok: 0, failed: [] }
  const { data: rows } = await supabase.from('proposals_v2').select('id,external_proposal_id,customer_snapshot').in('id', ids)
  const labelOf = new Map(((rows ?? []) as { id: string; external_proposal_id: string | null; customer_snapshot: { full_name?: string } | null }[])
    .map(r => [r.id, `${r.customer_snapshot?.full_name ?? 'Cliente'}${r.external_proposal_id ? ` · nº ${r.external_proposal_id}` : ''}`]))
  const result: BulkSellerResult = { ok: 0, failed: [] }
  for (const id of ids) {
    const { error } = await supabase.rpc('update_contract', { p_proposal: id, p_data: { seller_id: seller }, p_reason: reason || null })
    if (!error) { result.ok++; continue }
    const m = error.message ?? ''
    result.failed.push({ id, label: labelOf.get(id) ?? 'Contrato', reason: REASON.find(([re]) => re.test(m))?.[1] ?? 'não foi possível alterar' })
  }
  revalidatePath('/app/contratos')
  return result
}
