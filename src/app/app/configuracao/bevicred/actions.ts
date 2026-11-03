'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { testBevicredCredential } from '@/lib/bevicred.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { isUuid } from '@/lib/team'

export type CredentialState = { ok?: boolean; message?: string }

const SAVE_ERRORS: Record<string, string> = {
  bevicred_invalid_credential: 'Confira o código de parceiro (3 a 60 caracteres) e a chave da API (8 a 200 caracteres).',
  bevicred_invalid_label: 'Dê um nome à credencial (até 40 caracteres), por exemplo Sub.',
  bevicred_label_taken: 'Já existe uma credencial com esse nome nesta empresa.',
  bevicred_credential_not_found: 'Credencial não encontrada nesta empresa.',
}

// Admin of the company only. Saves (new credential, or new partner code and key for "Trocar chave") and tests at once.
// The key goes from the form straight to Vault; it is never returned, logged or put in a URL.
export async function saveBevicredCredential(_prev: CredentialState, formData: FormData): Promise<CredentialState> {
  const { organization, membership, user } = await requireAppContext()
  if (membership.role !== 'admin') return { ok: false, message: 'Somente o administrador da empresa cadastra credenciais.' }
  const id = String(formData.get('credential_id') ?? '')
  if (id && !isUuid(id)) return { ok: false, message: SAVE_ERRORS.bevicred_credential_not_found }
  const { data, error } = await createAdminClient().rpc('bevicred_save_credential', {
    p_actor: user.id, p_org: organization.id, p_id: id || null, p_label: String(formData.get('label') ?? ''),
    p_partner: String(formData.get('partner') ?? ''), p_key: String(formData.get('api_key') ?? ''),
  })
  if (error || typeof data !== 'string') {
    const code = Object.keys(SAVE_ERRORS).find(k => error?.message.includes(k))
    return { ok: false, message: code ? SAVE_ERRORS[code] : 'Não foi possível salvar. Nada foi alterado.' }
  }
  const r = await testBevicredCredential(organization.id, data)
  revalidatePath('/app/configuracao/bevicred')
  return { ok: r.ok, message: `Salvo. ${r.message}` }
}

export async function testBevicred(formData: FormData) {
  const { organization, membership } = await requireAppContext()
  const id = String(formData.get('credential_id') ?? '')
  if (membership.role !== 'admin' || !isUuid(id)) return
  await testBevicredCredential(organization.id, id)
  revalidatePath('/app/configuracao/bevicred')
}
