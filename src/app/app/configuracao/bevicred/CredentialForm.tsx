'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui'
import { saveBevicredCredential, type CredentialState } from './actions'

// New credential (with a name) or "Trocar chave" of an existing one (credentialId, no name). The key field is a password
// field and is never filled back.
export function CredentialForm({ credentialId }: { credentialId?: string }) {
  const [state, action, pending] = useActionState<CredentialState, FormData>(saveBevicredCredential, {})
  return (
    <form action={action} className="space-y-3">
      {credentialId && <input type="hidden" name="credential_id" value={credentialId} />}
      <div className="grid gap-3 sm:grid-cols-3">
        {!credentialId && (
          <label className="block text-[13px] font-medium text-ink-soft">Nome
            <input name="label" required maxLength={40} placeholder="Sub" className="field mt-1.5 w-full" />
          </label>
        )}
        <label className="block text-[13px] font-medium text-ink-soft">Código de parceiro
          <input name="partner" required maxLength={60} autoComplete="off" placeholder="SP18-00000" className="field mt-1.5 w-full" />
        </label>
        <label className="block text-[13px] font-medium text-ink-soft">Chave da API
          <input name="api_key" type="password" required maxLength={200} autoComplete="new-password" className="field mt-1.5 w-full" />
        </label>
      </div>
      <Button type="submit" disabled={pending}>{pending ? 'Salvando e testando...' : 'Salvar e testar'}</Button>
      {state.message && (
        <p role={state.ok ? 'status' : 'alert'} className={`rounded-lg px-3 py-2 text-sm ${state.ok ? 'bg-brand-soft text-brand-strong' : 'bg-[#FDE2E1] text-[#991B1B]'}`}>{state.message}</p>
      )}
    </form>
  )
}
