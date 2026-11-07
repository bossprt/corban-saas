'use client'

import { useFormStatus } from 'react-dom'

// Submit button that asks first (destructive or hard-to-undo actions: revoke, deactivate, replace a link). Cancelling the
// question sends nothing. Disabled while the form is being processed, like SubmitButton.
export function ConfirmSubmit({ children, confirm, className, pendingText = 'Enviando...', title }:
  { children: React.ReactNode; confirm: string; className?: string; pendingText?: string; title?: string }) {
  const { pending } = useFormStatus()
  return (
    <button type="submit" disabled={pending} aria-busy={pending} title={title} className={`${className ?? ''} disabled:opacity-60`}
      onClick={e => { if (!window.confirm(confirm)) e.preventDefault() }}>
      {pending ? pendingText : children}
    </button>
  )
}
