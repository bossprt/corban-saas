'use client'

import { useFormStatus } from 'react-dom'

// Disables itself while its form is being processed, so a double click cannot send the action twice. The database is still the real guard
// (idempotent RPCs / unique constraints); this only removes the temptation.
export function SubmitButton({ children, className, pendingText = 'Enviando...' }: { children: React.ReactNode; className?: string; pendingText?: string }) {
  const { pending } = useFormStatus()
  return <button type="submit" disabled={pending} aria-busy={pending} className={`${className ?? ''} disabled:opacity-60`}>{pending ? pendingText : children}</button>
}
