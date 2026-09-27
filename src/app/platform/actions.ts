'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { isPlanModule } from '@/lib/access'

const clean = (v: FormDataEntryValue | null) => String(v ?? '').trim()
const code = (v: string) => v.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40)
const go = (kind: 'ok'|'erro', msg: string): never => {
  revalidatePath('/platform')
  redirect(`/platform?${kind}=${encodeURIComponent(msg)}`)
}
async function gate() {
  const g = await requirePlatformAdmin()
  if (!g.ok) redirect('/login')
  return g
}

export async function addDocumentType(f: FormData) {
  await gate()
  const name=clean(f.get('name'))
  if(!name) go('erro','Informe o tipo de documento.')

  const admin=createAdminClient()
  const base=code(name) || 'DOCUMENTO'
  let generated=base
  let suffix=2

  while (true) {
    const {data,error}=await admin.from('document_types').select('id').eq('code',generated).maybeSingle()
    if(error) go('erro','Não foi possível validar o identificador do documento.')
    if(!data) break
    const tail=`_${suffix++}`
    generated=`${base.slice(0, Math.max(1, 40-tail.length))}${tail}`
  }

  const {error}=await admin.from('document_types').insert({code:generated,name,is_active:true})
  if(error) go('erro','Não foi possível cadastrar o tipo de documento.')
  go('ok','Tipo de documento cadastrado. O identificador técnico foi gerado automaticamente.')
}

// Switches one module for one company (plan limits). Platform administrators only; every change is audited.
export async function setOrganizationModule(f: FormData) {
  const g = await gate()
  const org = clean(f.get('organization_id'))
  const moduleKey = clean(f.get('module_key'))
  const enabled = clean(f.get('enabled')) === 'true'
  if (!/^[0-9a-f-]{36}$/i.test(org) || !isPlanModule(moduleKey)) go('erro', 'Dados inválidos.')
  const admin = createAdminClient()
  const { error } = await admin.from('organization_modules')
    .upsert({ organization_id: org, module_key: moduleKey, enabled, updated_by: g.userId, updated_at: new Date().toISOString() }, { onConflict: 'organization_id,module_key' })
  if (error) go('erro', 'Não foi possível alterar o módulo.')
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: g.userId, organization_id: org, action: 'organization_module.set', metadata: { module_key: moduleKey, enabled } })
  go('ok', `Módulo ${enabled ? 'ligado' : 'desligado'}.`)
}
