'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

const PATH='/app/cadastros/filiais'
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()
const back=(q:string):never=>{revalidatePath(PATH);redirect(PATH+'?'+q)}

export async function createBranch(f:FormData){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'manager'))return back('erro=sem_permissao')
  const code=text(f,'code').toUpperCase(),name=text(f,'name')
  if(!code||code.length>30||!name||name.length>120)return back('erro=invalido')
  const {error}=await supabase.from('organization_branches').insert({
    organization_id:membership.organization_id,
    code,
    name,
    branch_type:'branch',
  })
  return error?back('erro=duplicado'):back('ok=criado')
}

export async function setBranchActive(f:FormData){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'manager'))return back('erro=sem_permissao')
  const id=text(f,'id'),active=text(f,'active')==='true'
  const {error}=await supabase.from('organization_branches').update({is_active:active,updated_by:membership.user_id}).eq('id',id).eq('branch_type','branch')
  return error?back('erro=invalido'):back('ok=atualizado')
}
