'use server'

import { revalidatePath } from 'next/cache'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'

export type RecalcResult = { error?: string; ok: number; failed: { id: string; label: string; reason: string }[] }

// Why a contract could not be recalculated, as the screen says it.
const REASON: [RegExp, string][] = [
  [/contract_payout_received/, 'o vendedor já recebeu a comissão deste contrato'],
  [/commission_frozen/, 'contrato recusado ou cancelado'],
  [/proposal_without_seller/, 'o contrato não tem vendedor'],
  [/seller_without_group/, 'o vendedor não tem grupo'],
  [/group_rule_missing/, 'o grupo do vendedor não tem regra de repasse'],
  [/condition_not_found/, 'a tabela não tem linha para o prazo e o valor deste contrato'],
  [/condition_ambiguous/, 'há mais de uma linha da tabela para este contrato (abra o contrato e escolha)'],
  [/calculation_base_missing/, 'a linha da tabela tem % sem base de cálculo'],
  [/payout_exceeds_received/, 'a regra do grupo paga mais do que a empresa recebe'],
  [/not_authorized/, 'sem permissão para este contrato'],
]
const MAX_RECALC = 300

// Recalculates the chosen contracts one by one, through the same database call as "Recalcular" on the contract page
// (owner request 06/10/2026): the current table line, seller and group. Each contract stands alone: one that cannot be
// recalculated is listed with its reason and the others go on. The previous calculation stays as history.
export async function recalcContracts(formData: FormData): Promise<RecalcResult> {
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'propostas.edit') && !can(access, 'financeiro.edit')) return { error: 'Sem permissão para recalcular comissões.', ok: 0, failed: [] }
  const ids = [...new Set(formData.getAll('ids').map(String))].filter(isUuid)
  if (!ids.length) return { error: 'Marque pelo menos um contrato.', ok: 0, failed: [] }
  if (ids.length > MAX_RECALC) return { error: `Marque no máximo ${MAX_RECALC} contratos por vez.`, ok: 0, failed: [] }

  const { data: rows } = await supabase.from('proposals_v2').select('id,external_proposal_id,customer_snapshot').in('id', ids)
  const labelOf = new Map(((rows ?? []) as { id: string; external_proposal_id: string | null; customer_snapshot: { full_name?: string } | null }[])
    .map(r => [r.id, `${r.customer_snapshot?.full_name ?? 'Cliente'}${r.external_proposal_id ? ` · nº ${r.external_proposal_id}` : ''}`]))
  const result: RecalcResult = { ok: 0, failed: [] }
  for (const id of ids) {
    const { error } = await supabase.rpc('calculate_contract_commission', { p_proposal_id: id, p_condition_id: null })
    if (!error) { result.ok++; continue }
    const m = error.message ?? ''
    result.failed.push({ id, label: labelOf.get(id) ?? 'Contrato', reason: REASON.find(([re]) => re.test(m))?.[1] ?? 'não foi possível recalcular' })
  }
  revalidatePath('/app/contratos')
  return result
}
