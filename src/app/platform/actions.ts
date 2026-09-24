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

export async function addBank(f: FormData) {
  await gate()
  const name=clean(f.get('name'))
  const rawCode=clean(f.get('code'))
  const c=rawCode ? code(rawCode) : null
  if(!name) go('erro','Informe o nome da instituição.')
  const {error}=await createAdminClient().from('banks').insert({code:c,name,is_active:true})
  if(error) go('erro', error.code==='23505'?'Código já cadastrado.':'Não foi possível cadastrar a instituição.')
  go('ok','Instituição cadastrada.')
}

export async function updateBank(f: FormData) {
  await gate()
  const id=clean(f.get('id'))
  const name=clean(f.get('name'))
  const rawCode=clean(f.get('code'))
  const c=rawCode ? code(rawCode) : null
  if(!id || !name) go('erro','Instituição inválida ou sem nome.')
  const {error}=await createAdminClient().from('banks').update({name,code:c}).eq('id',id)
  if(error) go('erro', error.code==='23505'?'Código já cadastrado em outra instituição.':'Não foi possível atualizar a instituição.')
  go('ok','Instituição atualizada.')
}

export async function addProvider(f: FormData) {
  await gate()
  const name=clean(f.get('name')), c=code(clean(f.get('code'))), provider_type=clean(f.get('provider_type'))
  if(!name||!c||!['bank_direct','master','promotora','other'].includes(provider_type)) go('erro','Dados do provedor inválidos.')
  const {error}=await createAdminClient().from('providers').insert({code:c,name,provider_type,is_active:true})
  if(error) go('erro', error.code==='23505'?'Provedor/código já cadastrado.':'Não foi possível cadastrar o provedor.')
  go('ok','Provedor cadastrado.')
}

export async function addProduct(f: FormData) {
  await gate()
  const name=clean(f.get('name'))
  if(!name) go('erro','Informe o nome do produto.')

  const admin=createAdminClient()
  const base=code(name) || 'PRODUTO'
  let generated=base
  let suffix=2

  while (true) {
    const {data,error}=await admin.from('products').select('id').eq('code',generated).maybeSingle()
    if(error) go('erro','Não foi possível validar o identificador do produto.')
    if(!data) break
    const tail=`_${suffix++}`
    generated=`${base.slice(0, Math.max(1, 40-tail.length))}${tail}`
  }

  const {error}=await admin.from('products').insert({code:generated,name,is_active:true})
  if(error) go('erro','Não foi possível cadastrar o produto.')
  go('ok','Produto cadastrado. O identificador técnico foi gerado automaticamente.')
}

export async function addModality(f: FormData) {
  await gate()
  const product_id=clean(f.get('product_id')), name=clean(f.get('name'))
  if(!product_id||!name) go('erro','Selecione o produto e informe o tipo de contrato.')

  const admin=createAdminClient()
  const base=code(name) || 'TIPO_CONTRATO'
  let generated=base
  let suffix=2

  while (true) {
    const {data,error}=await admin.from('modalities').select('id').eq('product_id',product_id).eq('code',generated).maybeSingle()
    if(error) go('erro','Não foi possível validar o identificador do tipo de contrato.')
    if(!data) break
    const tail=`_${suffix++}`
    generated=`${base.slice(0, Math.max(1, 40-tail.length))}${tail}`
  }

  const {error}=await admin.from('modalities').insert({product_id,code:generated,name,is_active:true})
  if(error) go('erro','Não foi possível cadastrar o tipo de contrato.')
  go('ok','Tipo de contrato cadastrado. O identificador técnico foi gerado automaticamente.')
}

export async function addAgreement(f: FormData) {
  await gate()
  const bank_id=clean(f.get('bank_id')), name=clean(f.get('name'))
  if(!bank_id||!name) go('erro','Selecione a instituição e informe o convênio.')

  const admin=createAdminClient()
  const base=code(name) || 'CONVENIO'
  let generated=base
  let suffix=2

  while (true) {
    const {data,error}=await admin.from('agreements').select('id').eq('bank_id',bank_id).eq('code',generated).maybeSingle()
    if(error) go('erro','Não foi possível validar o identificador do convênio.')
    if(!data) break
    const tail=`_${suffix++}`
    generated=`${base.slice(0, Math.max(1, 40-tail.length))}${tail}`
  }

  const {error}=await admin.from('agreements').insert({bank_id,code:generated,name,is_active:true})
  if(error) go('erro','Não foi possível cadastrar o convênio.')
  go('ok','Convênio cadastrado. O identificador técnico foi gerado automaticamente.')
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
