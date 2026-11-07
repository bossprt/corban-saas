'use client'

// A transition with no way back (rejected, cancelled) asks before it is sent. The database still validates the transition.
export function ConfirmStateButton({ value, question, className, children }: { value: string; question: string; className?: string; children: React.ReactNode }) {
  return (
    <button type="submit" name="to_state" value={value} className={className}
      onClick={e => { if (!window.confirm(question)) e.preventDefault() }}>
      {children}
    </button>
  )
}
