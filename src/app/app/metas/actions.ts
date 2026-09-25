'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { isUuid } from '@/lib/team'

const back = (code: FeedbackCode): never => redirect(feedbackUrl('/app/metas', code))

export async function saveGoal(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const user = String(formData.get('user_id') ?? '')
  const month = String(formData.get('month') ?? '')
  const target = parseMoneyInput(formData.get('target'))
  if (!isUuid(user) || !/^\d{4}-\d{2}$/.test(month)) return back('erro:requisicao_invalida')
  if (target === 'invalid' || target === null) return back('erro:valor_invalido')
  const { error } = await supabase.rpc('set_seller_goal', { p_org: organization.id, p_user_id: user, p_month: `${month}-01`, p_target_amount: target })
  if (error) return back(classifyDbFeedback(error))
  revalidatePath('/app/metas')
  revalidatePath('/app/hoje')
  return back('ok:meta_salva')
}

export async function saveDistribution(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const mode = String(formData.get('distribution') ?? '')
  if (!['round_robin', 'queue', 'manual'].includes(mode)) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('set_lead_distribution', { p_org: organization.id, p_distribution: mode })
  if (error) return back(classifyDbFeedback(error))
  const receivers = new Set(formData.getAll('receives').map(String))
  for (const id of formData.getAll('membership_id').map(String)) {
    if (!isUuid(id)) continue
    const { error: e } = await supabase.rpc('set_member_receives_leads', { p_membership_id: id, p_receives: receivers.has(id) })
    if (e) return back(classifyDbFeedback(e))
  }
  revalidatePath('/app/metas')
  return back('ok:distribuicao_salva')
}
