'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { requirePlatformAdmin } from '@/lib/platform.server'

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
