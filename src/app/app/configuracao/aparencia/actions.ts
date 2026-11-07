'use server'

import { randomUUID } from 'node:crypto'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { checkLogo, LOGO_BUCKET, normalizeHex } from '@/lib/branding'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const PATH = '/app/configuracao/aparencia'
const go = (code: FeedbackCode): never => redirect(feedbackUrl(PATH, code))

// Colors and logo of the company. The database (set_org_branding) accepts it only from an active admin of the company
// and only a logo already stored in the company's own folder; the storage policy lets only that admin upload there.
export async function saveBranding(formData: FormData) {
  const { supabase, organization, membership } = await requireAppContext()
  if (membership.role !== 'admin') return go('erro:sem_permissao')
  const reset = formData.get('reset') === '1'
  const brand = reset ? null : normalizeHex(formData.get('brand_color'))
  const accent = reset ? null : normalizeHex(formData.get('accent_color'))
  if (!reset && (!brand || !accent)) return go('erro:aparencia_cor')

  let logo: string | null = null
  const file = formData.get('logo')
  if (!reset && file instanceof File && file.size > 0) {
    const bytes = new Uint8Array(await file.arrayBuffer())
    const c = checkLogo(file.size, file.type, bytes)
    if (!c.ok) return go(c.code)
    logo = `${organization.id}/${randomUUID()}.${c.ext}`
    const { error: up } = await supabase.storage.from(LOGO_BUCKET).upload(logo, bytes, { contentType: c.mime, upsert: false })
    if (up) return go('erro:aparencia_logo_envio')
  }

  const { error } = await supabase.rpc('set_org_branding', {
    p_org: organization.id, p_brand: brand, p_accent: accent, p_logo: logo, p_remove_logo: formData.get('remove_logo') === '1',
  })
  if (error) return go(/invalid_color/.test(error.message) ? 'erro:aparencia_cor' : /invalid_logo/.test(error.message) ? 'erro:aparencia_logo_formato' : classifyDbFeedback(error))
  revalidatePath('/app', 'layout')
  return go('ok:aparencia_salva')
}
