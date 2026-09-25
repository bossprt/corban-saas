'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui'
import { createApiKey, type CreateKeyState } from './actions'

export function CreateKeyForm() {
  const [state, action, pending] = useActionState<CreateKeyState, FormData>(createApiKey, {})
  return (
    <div className="space-y-3">
      <form action={action} className="flex flex-wrap items-end gap-3">
        <label className="text-[13px] font-medium text-ink-soft">Nome da chave
          <input name="name" required minLength={2} maxLength={60} placeholder="DeskcommCRM" className="field mt-1.5 w-72" />
        </label>
        <Button type="submit" disabled={pending}>{pending ? 'Criando...' : 'Criar chave'}</Button>
      </form>
      {state.error && <p role="alert" className="rounded-lg bg-[#FDE2E1] px-3 py-2 text-sm text-[#991B1B]">{state.error}</p>}
      {state.key && (
        <div role="status" className="rounded-[12px] border border-brand/30 bg-brand-soft p-4">
          <p className="text-sm font-semibold text-brand-strong">Copie a chave agora. Ela não será mostrada de novo.</p>
          <code className="mt-2 block break-all rounded-lg bg-surface px-3 py-2 font-mono text-[13px] text-ink" data-testid="new-api-key">{state.key}</code>
        </div>
      )}
    </div>
  )
}
