import type { ReactNode } from 'react'

// Frame of the access screens (login, password recovery, new password, company picker): same look as the login.
export function AuthShell({ subtitle, children }: { subtitle: string; children: ReactNode }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-canvas px-4 py-10">
      <div className="w-full max-w-[400px]">
        <div className="mb-8 flex items-center gap-3">
          <div className="flex size-10 items-center justify-center rounded-xl bg-brand text-lg font-bold text-white" aria-hidden>C</div>
          <div>
            <div className="text-xl font-bold tracking-tight text-ink">Corban</div>
            <p className="text-sm text-muted">{subtitle}</p>
          </div>
        </div>
        <div className="rounded-[16px] border border-line bg-surface p-6 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">{children}</div>
      </div>
    </main>
  )
}

export const authLabel = 'mb-1.5 block text-[13px] font-medium text-ink-soft'
export const authButton = 'h-11 w-full rounded-[10px] bg-brand text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-60'
export const authError = 'rounded-lg bg-[#FDE2E1] px-3 py-2 text-sm text-[#991B1B]'
