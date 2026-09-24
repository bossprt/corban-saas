'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'
import { parsePercentInput } from '@/lib/percent-input'

const back = (code: FeedbackCode): never => redirect(feedbackUrl('/app/configuracao/comissao', code))

// Saves a new version of a rule. The database checks who may, the scope and the limits.
export async function saveRule(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  // The default rule posts scope_kind=global; a specific rule posts target=<kind>:<id>.
  const [targetKind, targetId] = String(formData.get('target') ?? '').split(':')
  const scope = String(formData.get('scope_kind') ?? targetKind ?? '')
  const scopeId = targetId ?? ''
  if (!['global', 'bank', 'table', 'group', 'seller'].includes(scope) || (scope !== 'global' && !isUuid(scopeId))) return back('erro:requisicao_invalida')
  const mode = String(formData.get('mode') ?? '')
  const fields = ['tax_rate_pct', 'profit_pct', 'manager_pct', 'supervisor_pct', 'originator_pct'].map(k => parsePercentInput(formData.get(k)))
  if (fields.includes('invalid')) return back('erro:percentual_invalido')
  const [tax, profit, manager, supervisor, originator] = fields as (string | null)[]
  const deferred = String(formData.get('pay_deferred') ?? '')
  const { error } = await supabase.rpc('save_commission_rule', {
    p_org: organization.id, p_scope_kind: scope, p_scope_id: scope === 'global' ? null : scopeId,
    p_mode: mode === 'cascade' || mode === 'group_table' ? mode : null,
    p_tax_rate_pct: scope === 'global' ? tax : null, p_profit_pct: profit, p_manager_pct: manager, p_supervisor_pct: supervisor, p_originator_pct: originator,
    p_pay_deferred: deferred === 'true' ? true : deferred === 'false' ? false : null,
    p_note: String(formData.get('note') ?? '').trim() || null,
  })
  if (error) {
    if (/commission_rule_cascade_split|check constraint/.test(error.message ?? '')) return back('erro:rateio_acima_100')
    return back(classifyDbFeedback(error))
  }
  revalidatePath('/app/configuracao/comissao')
  return back('ok:regra_comissao_salva')
}

export async function setTaxExempt(formData: FormData) {
  const { supabase } = await requireAppContext()
  const kind = String(formData.get('kind') ?? '')
  const id = String(formData.get('id') ?? '')
  if (!['bank', 'provider'].includes(kind) || !isUuid(id)) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('set_paying_source_tax_exempt', { p_kind: kind, p_id: id, p_exempt: String(formData.get('exempt')) === 'true' })
  if (error) return back(classifyDbFeedback(error))
  revalidatePath('/app/configuracao/comissao')
  return back('ok:isencao_salva')
}
