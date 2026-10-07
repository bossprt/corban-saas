'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui'
import { testBevicred, type ProbeState } from './actions'

export function TestButton() {
  const [state, action, pending] = useActionState<ProbeState>(testBevicred, {})
  return (
    <div className="space-y-3">
      <form action={action}><Button type="submit" disabled={pending}>{pending ? 'Testando...' : 'Testar conexão Bevicred'}</Button></form>
      {state.message && (
        <p role={state.ok ? 'status' : 'alert'} className={`rounded-lg px-3 py-2 text-sm ${state.ok ? 'bg-brand-soft text-brand-strong' : 'bg-[#FDE2E1] text-[#991B1B]'}`}>
          {state.message}{state.at && <span className="block text-xs opacity-80">Teste em {state.at}</span>}
        </p>
      )}
    </div>
  )
}
