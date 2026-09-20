'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { requirePlatformAdmin } from '@/lib/platform.server'

const clean = (v: FormDataEntryValue | null) => String(v ?? '').trim()
const code = (v: string) => v.toUpperCase().replace(/[^A-Z0-9_-]/g, '').slice(0, 40)
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
  const name=clean(f.get('name')), c=code(clean(f.get('code')))
  if(!name||!c) go('erro','Informe código e nome do produto.')
  const {error}=await createAdminClient().from('products').insert({code:c,name,is_active:true})
  if(error) go('erro', error.code==='23505'?'Produto/código já cadastrado.':'Não foi possível cadastrar o produto.')
  go('ok','Produto cadastrado.')
}

export async function addModality(f: FormData) {
  await gate()
  const product_id=clean(f.get('product_id')), name=clean(f.get('name')), c=code(clean(f.get('code')))
  if(!product_id||!name||!c) go('erro','Selecione o produto e informe código/nome.')
  const {error}=await createAdminClient().from('modalities').insert({product_id,code:c,name,is_active:true})
  if(error) go('erro', error.code==='23505'?'Modalidade/código já cadastrado para esse produto.':'Não foi possível cadastrar a modalidade.')
  go('ok','Modalidade cadastrada.')
}

export async function addAgreement(f: FormData) {
  await gate()
  const bank_id=clean(f.get('bank_id')), name=clean(f.get('name')), c=code(clean(f.get('code')))
  if(!bank_id||!name||!c) go('erro','Selecione a instituição e informe código/nome do convênio.')
  const {error}=await createAdminClient().from('agreements').insert({bank_id,code:c,name,is_active:true})
  if(error) go('erro', error.code==='23505'?'Convênio/código já cadastrado para essa instituição.':'Não foi possível cadastrar o convênio.')
  go('ok','Convênio cadastrado.')
}

export async function addDocumentType(f: FormData) {
  await gate()
  const name=clean(f.get('name')), c=code(clean(f.get('code')))
  if(!name||!c) go('erro','Informe código e nome do documento.')
  const {error}=await createAdminClient().from('document_types').insert({code:c,name,is_active:true})
  if(error) go('erro', error.code==='23505'?'Documento/código já cadastrado.':'Não foi possível cadastrar o documento.')
  go('ok','Tipo de documento cadastrado.')
}
