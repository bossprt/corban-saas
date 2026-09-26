'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { normalizePct } from '@/lib/commission/groupRule'
import { isUuid } from '@/lib/team'

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
    : /condition_not_found/.test(m) ? 'erro:comissao_sem_condicao'
    : /condition_ambiguous/.test(m) ? 'erro:comissao_ambigua'
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
  const table = text(f, 'table_version_id'), seller = text(f, 'seller_id')
  if (!isUuid(table) || (seller && !isUuid(seller))) return back(id, 'erro:requisicao_invalida', '#contrato')
  const money = (k: string) => parseMoneyInput(f.get(k))
  const requested = money('requested_amount'), released = money('released_amount'), installment = money('installment_amount')
  if (requested === 'invalid' || released === 'invalid' || installment === 'invalid' || (!requested && !released)) return back(id, 'erro:valor_invalido', '#contrato')
  const termText = text(f, 'term')
  if (termText && !/^\d{1,3}$/.test(termText)) return back(id, 'erro:prazo_invalido', '#contrato')
  const data = {
    table_version_id: table, seller_id: seller, term: termText,
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
