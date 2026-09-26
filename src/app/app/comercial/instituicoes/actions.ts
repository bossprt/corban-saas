'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { normalizePct } from '@/lib/commission/groupRule'
import { isUuid } from '@/lib/team'

const PATH = '/app/comercial/instituicoes'
const go = (code: FeedbackCode): never => { revalidatePath(PATH); return redirect(feedbackUrl(PATH, code)) }

// IR withheld at source by the bank on the commissions it pays (Daycoval 0,5%). Empty = 0.
export async function saveBankIrWithheld(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return go('erro:sem_permissao')
  const bank = String(f.get('bank_id') ?? '')
  const raw = String(f.get('ir_withheld_pct') ?? '').replace(/%$/, '').trim()
  const pct = raw === '' ? '' : normalizePct(raw)
  if (!isUuid(bank)) return go('erro:requisicao_invalida')
  if (pct === null) return go('erro:ir_retido_invalido')
  const { error } = await supabase.rpc('set_bank_ir_withheld', { p_bank: bank, p_pct: pct })
  if (error) return go(/invalid_ir_withheld/.test(error.message ?? '') ? 'erro:ir_retido_invalido' : classifyDbFeedback(error))
  return go('ok:ir_retido_salvo')
}
