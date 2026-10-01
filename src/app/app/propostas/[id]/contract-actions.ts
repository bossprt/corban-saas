'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { normalizePct } from '@/lib/commission/groupRule'
import { isUuid } from '@/lib/team'
import { originDetails } from '@/lib/proposals/origin'

const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const back = (id: string, code: FeedbackCode, anchor = ''): never => {
  revalidatePath(`/app/propostas/${id}`)
  return redirect(feedbackUrl(`/app/propostas/${id}${anchor}`, code))
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
    : /condition_not_found/.test(m) ? 'erro:comissao_sem_condicao'
    : /condition_ambiguous/.test(m) ? 'erro:comissao_ambigua'
    : /contract_type_not_in_table|contract_type_not_found/.test(m) ? 'erro:tipo_fora_da_tabela'
    : /invalid_outstanding_balance|invalid_origin/.test(m) ? 'erro:saldo_devedor_invalido'
    : /calculation_base_missing/.test(m) ? 'erro:comissao_sem_base'
    : /seller_without_group/.test(m) ? 'erro:comissao_vendedor_sem_grupo'
    : /group_rule_missing/.test(m) ? 'erro:comissao_grupo_sem_regra'
    : /proposal_without_seller/.test(m) ? 'erro:comissao_sem_vendedor'
    : /payout_exceeds_received/.test(m) ? 'erro:comissao_excede'
    : fallback

// The contract file saved as a whole (part C2): the database records before -> after and recalculates the commission.
export async function updateContract(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return redirect('/app/contratos')
  const { supabase } = await requireAppContext()
  const table = text(f, 'table_version_id'), seller = text(f, 'seller_id'), contractType = text(f, 'contract_type_id')
  if (!isUuid(table) || !isUuid(contractType) || (seller && !isUuid(seller))) return back(id, 'erro:requisicao_invalida', '#contrato')
  const money = (k: string) => parseMoneyInput(f.get(k))
  const requested = money('requested_amount'), released = money('released_amount'), installment = money('installment_amount')
  if (requested === 'invalid' || released === 'invalid' || installment === 'invalid' || (!requested && !released)) return back(id, 'erro:valor_invalido', '#contrato')
  const termText = text(f, 'term')
  if (termText && !/^\d{1,3}$/.test(termText)) return back(id, 'erro:prazo_invalido', '#contrato')
  const formalization = text(f, 'formalization'), paidOn = text(f, 'paid_to_client_on')
  if (!['digital', 'physical'].includes(formalization) || (paidOn && !/^\d{4}-\d{2}-\d{2}$/.test(paidOn))) return back(id, 'erro:requisicao_invalida', '#contrato')
  const origin = originDetails(f)
  if (!origin.ok) return back(id, 'erro:saldo_devedor_invalido', '#contrato')
  const data = {
    ...origin.details,
    table_version_id: table, contract_type_id: contractType, seller_id: seller, term: termText, formalization, ...(paidOn ? { paid_to_client_on: paidOn } : {}),
    requested_amount: requested ?? '', released_amount: released ?? '', installment_amount: installment ?? '',
  }
  const { error } = await supabase.rpc('update_contract', { p_proposal: id, p_data: data, p_reason: text(f, 'reason') || null })
  if (error) return back(id, dbCode(error.message ?? '', classifyDbFeedback(error)), '#contrato')
  return back(id, 'ok:contrato_atualizado', '#contrato')
}

// Change what the seller gets for one commission type ("2,5" = % of the base, "R$ 25,00" = fixed), or back to the rule.
export async function setPayoutOverride(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return redirect('/app/contratos')
  const { supabase } = await requireAppContext()
  const component = text(f, 'component'), clear = text(f, 'clear') === '1', reason = text(f, 'reason')
  if (!/^[a-z0-9_]{1,40}$/.test(component)) return back(id, 'erro:requisicao_invalida', '#comissao')
  if (reason.length < 3) return back(id, 'erro:repasse_motivo', '#comissao')
  let kind: string | null = null, value: string | null = null
  if (!clear) {
    kind = text(f, 'kind') === 'fixed_brl' ? 'fixed_brl' : 'percentage'
    const raw = text(f, 'value')
    const parsed = kind === 'fixed_brl' ? parseMoneyInput(raw) : normalizePct(raw.replace(/%$/, ''))
    if (!parsed || parsed === 'invalid') return back(id, 'erro:repasse_invalido', '#comissao')
    value = parsed
  }
  const { error } = await supabase.rpc('set_payout_override', { p_proposal: id, p_component: component, p_kind: kind, p_value: value, p_reason: reason })
  if (error) return back(id, dbCode(error.message ?? '', classifyDbFeedback(error)), '#comissao')
  return back(id, clear ? 'ok:repasse_regra' : 'ok:repasse_alterado', '#comissao')
}

export async function addContractNote(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return redirect('/app/contratos')
  const note = text(f, 'note')
  if (!note || note.length > 2000) return back(id, 'erro:observacao_invalida', '#historico')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('add_contract_note', { p_proposal: id, p_text: note })
  if (error) return back(id, classifyDbFeedback(error), '#historico')
  return back(id, 'ok:observacao_salva', '#historico')
}

// Part C3: one physical milestone (received by the company, sent to the bank, received by the bank), in order.
export async function setContractPhysical(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return redirect('/app/contratos')
  const step = text(f, 'step'), at = text(f, 'at')
  if (!['received', 'sent', 'bank'].includes(step) || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(at)) return back(id, 'erro:fisico_data', '#fisico')
  const { supabase } = await requireAppContext()
  // datetime-local is Brazil's local time (UTC-3).
  const { error } = await supabase.rpc('set_contract_physical', { p_proposal: id, p_step: step, p_at: `${at}:00-03:00` })
  if (error) {
    const m = error.message ?? ''
    return back(id, /out_of_order/.test(m) ? 'erro:fisico_ordem' : /invalid_physical_date/.test(m) ? 'erro:fisico_data' : classifyDbFeedback(error), '#fisico')
  }
  return back(id, 'ok:fisico_registrado', '#fisico')
}

// Part C3: a payment of this contract's commission already made outside Corban (owner only).
export async function registerExternalPayout(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return redirect('/app/contratos')
  const paidOn = text(f, 'paid_on'), reference = text(f, 'reference')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn) || reference.length < 3) return back(id, 'erro:repasse_comprovante', '#comissao')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('register_external_payout', { p_proposal: id, p_paid_on: paidOn, p_reference: reference })
  if (error) {
    const m = error.message ?? ''
    return back(id, /nothing_to_pay/.test(m) ? 'erro:repasse_nada_a_pagar' : /invalid_paid_on|reference_required/.test(m) ? 'erro:repasse_comprovante' : classifyDbFeedback(error), '#comissao')
  }
  return back(id, 'ok:repasse_pago_fora', '#comissao')
}

// $ Commission receipt registered by hand (owner request 29/09/2026): a bank without report, or money seen in the account
// before the report. The database runs it as a one-line report of the contract's paying source: expected value, duplicate
// and installment rules, reconciliation and finance entry exactly as for a file. Money is decimal text, never a float.
export async function registerManualReceipt(f: FormData) {
  const id = text(f, 'proposal_id')
  if (!isUuid(id)) return redirect('/app/contratos')
  const kind = text(f, 'kind'), receivedOn = text(f, 'received_on'), installment = text(f, 'installment')
  const amount = parseMoneyInput(text(f, 'amount'))
  if (!['upfront', 'deferred', 'chargeback'].includes(kind)) return back(id, 'erro:requisicao_invalida', '#comissao')
  if (amount === null || amount === 'invalid') return back(id, 'erro:recebimento_valor', '#comissao')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(receivedOn)) return back(id, 'erro:recebimento_data', '#comissao')
  if (installment && (!/^\d{1,4}$/.test(installment) || kind !== 'deferred')) return back(id, 'erro:recebimento_parcela', '#comissao')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('register_manual_receipt', {
    p_proposal_id: id, p_kind: kind, p_amount: amount, p_received_on: receivedOn,
    p_installment: installment ? Number(installment) : null, p_note: text(f, 'note').slice(0, 100),
  })
  if (error) {
    const m = error.message ?? ''
    const code: FeedbackCode = /manual_receipt_duplicate/.test(m) ? 'erro:recebimento_duplicado'
      : /manual_receipt_no_calc/.test(m) ? 'erro:recebimento_sem_calculo'
      : /installment/.test(m) ? 'erro:recebimento_parcela'
      : /invalid_receipt_date/.test(m) ? 'erro:recebimento_data'
      : /invalid_receipt_amount/.test(m) ? 'erro:recebimento_valor'
      : /receipt_source_not_found/.test(m) ? 'erro:recebimento_fonte'
      : /not_authorized/.test(m) ? 'erro:sem_permissao'
      : classifyDbFeedback(error)
    return back(id, code, '#comissao')
  }
  revalidatePath('/app/financeiro'); revalidatePath('/app/financeiro/conciliacao')
  return back(id, 'ok:recebimento_registrado', '#comissao')
}
