'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { classifyDbFeedback, FEEDBACK, type FeedbackCode } from '@/lib/feedback'
import { sellerData } from '@/app/app/cadastros/vendedores/sellerData'

const ERRORS: [RegExp, FeedbackCode][] = [
  [/signup_link_closed/, 'erro:cadastro_link_fechado'],
  [/signup_rate_limited/, 'erro:cadastro_link_limite'],
  [/signup_already_pending/, 'erro:cadastro_link_pendente'],
  [/signup_invalid/, 'erro:requisicao_invalida'],
  [/seller_name_required/, 'erro:vendedor_nome'],
  [/seller_tax_id_invalid/, 'erro:vendedor_documento'],
  [/seller_category_invalid/, 'erro:vendedor_invalido'],
  [/seller_mobile_required/, 'erro:vendedor_celular'],
  [/seller_email_required/, 'erro:vendedor_email'],
]

// The public registration form (05/11/2026): no login, the link token says which company and seller group. The request
// waits for the administrator's approval. The answer never says whether the document is already a seller there.
export async function submitSignup(token: string, f: FormData): Promise<{ error: string }> {
  if (!/^[A-Za-z0-9_-]{20,64}$/.test(token)) return { error: FEEDBACK['erro:cadastro_link_fechado'] }
  const done = `/cadastro/${token}?enviado=1`
  // Field hidden from people: only robots fill it. They get the same answer and nothing is stored.
  if (String(f.get('website') ?? '').trim()) redirect(done)
  // The database keeps only the form's fields: group, branch and payment rules from here are dropped.
  const data = sellerData(f)
  const supabase = await createClient()
  const { error } = await supabase.rpc('seller_signup_submit', { p_token: token, p_data: data })
  if (error) {
    const m = error.message ?? ''
    return { error: FEEDBACK[ERRORS.find(([re]) => re.test(m))?.[1] ?? classifyDbFeedback(error)] }
  }
  redirect(done)
}
