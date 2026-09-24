'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'

const back = (code: FeedbackCode): never => redirect(feedbackUrl('/app/configuracao/etapas', code))

export async function saveStage(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = String(formData.get('stage_id') ?? '')
  const name = String(formData.get('name') ?? '').trim()
  const order = Number.parseInt(String(formData.get('sort_order') ?? ''), 10)
  const slaText = String(formData.get('sla_hours') ?? '').trim()
  const slaHours = slaText === '' ? null : Number.parseInt(slaText, 10)
  if (!isUuid(id) || name.length < 2 || !Number.isInteger(order) || (slaHours !== null && (!Number.isInteger(slaHours) || slaHours < 0 || slaHours > 8760))) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('update_operational_stage', {
    p_stage_id: id, p_name: name, p_sort_order: order, p_sla_minutes: slaHours === null ? null : slaHours * 60, p_is_active: formData.get('is_active') === 'true',
  })
  if (error) {
    const m = error.message ?? ''
    if (/last_stage_of_state/.test(m)) return back('erro:ultima_etapa')
    if (/stage_in_use/.test(m)) return back('erro:etapa_em_uso')
    return back(classifyDbFeedback(error))
  }
  revalidatePath('/app/configuracao/etapas')
  revalidatePath('/app/propostas')
  return back('ok:etapa_salva')
}
