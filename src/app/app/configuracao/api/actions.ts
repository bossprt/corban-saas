'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'

export type CreateKeyState = { key?: string; error?: string }

// Returns the new key to the page state (shown once); it never goes into a URL, a redirect or a log.
export async function createApiKey(_prev: CreateKeyState, formData: FormData): Promise<CreateKeyState> {
  const { supabase, organization, membership } = await requireAppContext()
  if (membership.role !== 'admin') return { error: 'Somente o administrador cria chaves.' }
  const name = String(formData.get('name') ?? '').trim()
  if (name.length < 2 || name.length > 60) return { error: 'Dê um nome à chave (2 a 60 caracteres), por exemplo DeskcommCRM.' }
  const { data, error } = await supabase.rpc('create_api_key', { p_org: organization.id, p_name: name, p_scopes: ['leads.write'] })
  if (error) return { error: 'Não foi possível criar a chave. Nada foi alterado.' }
  const row = (Array.isArray(data) ? data[0] : data) as { api_key?: string } | null
  revalidatePath('/app/configuracao/api')
  return row?.api_key ? { key: row.api_key } : { error: 'Não foi possível criar a chave.' }
}

export async function revokeApiKey(formData: FormData) {
  const { supabase, membership } = await requireAppContext()
  const id = String(formData.get('key_id') ?? '')
  if (membership.role !== 'admin' || !isUuid(id)) return
  await supabase.rpc('revoke_api_key', { p_key_id: id })
  revalidatePath('/app/configuracao/api')
}
