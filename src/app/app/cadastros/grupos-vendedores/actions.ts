'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

const PATH='/app/cadastros/grupos-vendedores'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const back=(q:string):never=>{revalidatePath(PATH);redirect(PATH+'?'+q)}

export async function createSellerClassification(f:FormData){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'manager'))return back('erro=sem_permissao')
  const name=text(f,'name')
  if(!name||name.length>80)return back('erro=invalido')
  const {error}=await supabase.from('seller_groups').insert({
    organization_id:membership.organization_id,
    name,
  })
  return error?back('erro=duplicado'):back('ok=criado')
}

export async function updateSellerClassification(f:FormData){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'manager'))return back('erro=sem_permissao')
  const id=text(f,'id'),name=text(f,'name'),active=text(f,'active')==='true'
  if(!id||!name||name.length>80)return back('erro=invalido')
  const {error}=await supabase.from('seller_groups').update({
    name,
    is_active:active,
  }).eq('id',id)
  return error?back('erro=invalido'):back('ok=atualizado')
}
