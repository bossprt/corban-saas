'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isBasis, normalizePct, parseReference, type RuleItemInput } from '@/lib/commission/groupRule'
import { isUuid } from '@/lib/team'

const LIST = '/app/comercial/grupos'
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()

function dbError(message: string): FeedbackCode | null {
  if (/invalid_group_name/.test(message)) return 'erro:grupo_nome'
  if (/invalid_rule_pct|invalid_hierarchy_pct/.test(message)) return 'erro:grupo_percentual'
  if (/invalid_reference_group/.test(message)) return 'erro:grupo_referencia'
  if (/group_column_in_use/.test(message)) return 'erro:grupo_coluna_em_uso'
  if (/rule_items_incomplete|invalid_rule_items|own_production_has_no_payout|invalid_hierarchy_basis/.test(message)) return 'erro:grupo_regra_incompleta'
  if (/commission_groups_name_key|duplicate key/.test(message)) return 'erro:grupo_nome_repetido'
  return null
}

// Create or change a seller group with a new version of its payout rule (one database call, atomic).
export async function saveSellerGroup(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  const groupId = text(f, 'group_id')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(groupId ? `${LIST}/${groupId}` : `${LIST}/novo`, code))
  if (!atLeast(membership.role, 'manager')) return back('erro:sem_permissao')
  if (groupId && !isUuid(groupId)) return back('erro:requisicao_invalida')
  const name = text(f, 'name')
  if (name.length < 1 || name.length > 80) return back('erro:grupo_nome')
  const own = f.get('own_production') === 'on'
  const supervisorBasis = text(f, 'supervisor_basis'), managerBasis = text(f, 'manager_basis')
  const supervisorPct = normalizePct(text(f, 'supervisor_pct') || '0'), managerPct = normalizePct(text(f, 'manager_pct') || '0')
  if (!isBasis(supervisorBasis) || !isBasis(managerBasis)) return back('erro:grupo_regra_incompleta')
  if (supervisorPct === null || managerPct === null) return back('erro:grupo_percentual')

  const items: RuleItemInput[] = []
  if (!own) {
    for (const component of f.getAll('component').map(String)) {
      const ref = parseReference(text(f, `ref_${component}`))
      const pct = normalizePct(text(f, `pct_${component}`) || '0')
      if (!ref) return back('erro:grupo_regra_incompleta')
      if (pct === null) return back('erro:grupo_percentual')
      items.push({ component, reference: ref.reference, group: ref.group, pct })
    }
  }

  const { data, error } = await supabase.rpc('save_seller_group', {
    p_org: membership.organization_id, p_group: groupId || null, p_name: name, p_own_production: own, p_items: items,
    p_supervisor_basis: supervisorBasis, p_supervisor_pct: supervisorPct, p_manager_basis: managerBasis, p_manager_pct: managerPct,
  })
  if (error) return back(dbError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(LIST)
  redirect(feedbackUrl(`${LIST}/${data as string}`, 'ok:grupo_salvo'))
}
