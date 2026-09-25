'use client'

import { useEffect, useState, useTransition } from 'react'
import { Eye, EyeOff } from 'lucide-react'
import { revealRegistrationPassword } from '../actions'

// Shows the registration password for 30 seconds. Every reveal is recorded by the database; nothing goes into the URL.
export function RevealPassword({ registrationId }: { registrationId: string }) {
  const [value, setValue] = useState<string | null>(null)
  const [message, setMessage] = useState('')
  const [pending, start] = useTransition()

  useEffect(() => {
    if (value === null) return
    const t = setTimeout(() => setValue(null), 30_000)
    return () => clearTimeout(t)
  }, [value])

  if (value !== null) {
    return (
      <span className="inline-flex items-center gap-2">
        <code className="rounded bg-surface-muted px-1.5 py-0.5 font-mono text-[13px] text-ink">{value}</code>
        <button type="button" onClick={() => setValue(null)} className="inline-flex items-center gap-1 text-xs text-muted hover:text-ink"><EyeOff size={13} aria-hidden />Ocultar</button>
      </span>
    )
  }
  return (
    <span className="inline-flex items-center gap-2">
      <span className="font-mono text-[13px] text-muted">••••••••</span>
      <button type="button" disabled={pending} className="inline-flex items-center gap-1 text-xs text-brand hover:text-brand-strong disabled:opacity-60"
        onClick={() => start(async () => {
          setMessage('')
          const r = await revealRegistrationPassword(registrationId)
          if (r.error) setMessage(r.error)
          else setValue(r.password ?? '')
        })}>
        <Eye size={13} aria-hidden />{pending ? 'Abrindo...' : 'Mostrar senha'}
      </button>
      {message && <span role="alert" className="text-xs text-[#991B1B]">{message}</span>}
    </span>
  )
}
