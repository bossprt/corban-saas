'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

// Improvement requests (owner, 08/10/2026): the database gives the protocol; the page shows it.
export async function submitImprovement(f: FormData) {
  const { supabase, organization } = await requireAppContext()
  const kind = String(f.get('kind') ?? ''), title = String(f.get('title') ?? '').trim(), body = String(f.get('body') ?? '').trim()
  const page = String(f.get('page') ?? '')
  const fail = (e: string): never => redirect(`/app/melhorias?erro=${e}`)
  if (!['improvement', 'bug', 'question'].includes(kind)) return fail('tipo')
  if (title.length < 3 || title.length > 120) return fail('titulo')
  if (body.length < 10 || body.length > 4000) return fail('descricao')
  const { data, error } = await supabase.rpc('submit_improvement_request', {
    p_org: organization.id, p_kind: kind, p_title: title, p_body: body, p_page: /^\/app[A-Za-z0-9/_-]{0,195}$/.test(page) ? page : null,
  })
  if (error) return fail(/too_many_requests/.test(error.message ?? '') ? 'limite' : 'envio')
  revalidatePath('/app/melhorias')
  return redirect(`/app/melhorias?protocolo=${encodeURIComponent(String(data))}`)
}
