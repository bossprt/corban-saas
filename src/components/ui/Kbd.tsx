import type { ReactNode } from 'react'

export function Kbd({ children }: { children: ReactNode }) {
  return <kbd className="rounded-none border border-line px-1.5 py-0.5 font-mono text-[11px] text-muted">{children}</kbd>
}
