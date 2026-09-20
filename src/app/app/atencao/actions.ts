'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'

const PATH = '/app/atencao'
const go = (code: FeedbackCode): never => { revalidatePath(PATH); return redirect(feedbackUrl(PATH, code)) }
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const SNOOZE_DAYS = new Set(['1', '3', '7'])

// Resolve / snooze / dismiss / reopen an attention item. The database is the authority (role, status machine, mandatory reason to dismiss, append-only history);
// this only fails early. An item never changes business data: it points at the screen where a person acts.
export async function decideAttention(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return go('erro:sem_permissao')
  const id = text(f, 'item_id'), action = text(f, 'action'), note = text(f, 'note')
  if (!isUuid(id) || !['resolve', 'dismiss', 'snooze', 'reopen'].includes(action)) return go('erro:atencao_invalida')
  if (action === 'dismiss' && note.length < 3) return go('erro:atencao_nota')
  let until: string | null = null
  if (action === 'snooze') {
    const days = text(f, 'days')
    if (!SNOOZE_DAYS.has(days)) return go('erro:atencao_invalida')
    until = new Date(Date.now() + Number(days) * 24 * 3600 * 1000).toISOString()
  }
  const { error } = await supabase.rpc('decide_attention_item', { p_item: id, p_action: action, p_note: note ? note.slice(0, 500) : null, p_snooze_until: until })
  if (error) {
    if (/note_required/.test(error.message ?? '')) return go('erro:atencao_nota')
    if (/item_not_found|item_already_resolved|invalid_action|invalid_snooze/.test(error.message ?? '')) return go('erro:atencao_invalida')
    return go(classifyDbFeedback(error))
  }
  return go('ok:atencao_atualizada')
}
