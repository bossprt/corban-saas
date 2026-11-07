'use client'

import { useEffect, useState } from 'react'
import { usePathname, useSearchParams } from 'next/navigation'
import { FEEDBACK, feedbackTone, isFeedbackCode } from '@/lib/feedback'

// Shows the outcome of the last action. The text comes from a fixed whitelist keyed by the ?f= code; the code is removed from the address bar
// afterwards so a refresh does not repeat the message. The message belongs to the page where it arrived: moving to another page hides it
// (audit 06/11/2026: "Cadastro recusado" showed up on the next seller opened).
export function FlashBanner() {
  const raw = useSearchParams().get('f')
  const pathname = usePathname()
  const [flash, setFlash] = useState<{ code: string; path: string } | null>(null)
  useEffect(() => {
    if (!raw) return
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setFlash({ code: raw, path: pathname })
    const url = new URL(window.location.href)
    url.searchParams.delete('f')
    window.history.replaceState(null, '', url.pathname + (url.search || '') + url.hash)
  }, [raw, pathname])
  // Forget it once the page changes, so coming back later does not bring it back either.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { setFlash(f => (f && f.path !== pathname ? null : f)) }, [pathname])
  const code = flash && flash.path === pathname ? flash.code : null
  if (!code || !isFeedbackCode(code)) return null
  const ok = feedbackTone(code) === 'ok'
  return <div role={ok ? 'status' : 'alert'} className={`mb-5 rounded-xl border p-3 text-sm ${ok ? 'border-emerald-500/40 bg-emerald-500/10 text-emerald-200' : 'border-amber-500/40 bg-amber-500/10 text-amber-200'}`}>
    {FEEDBACK[code]}
    <button type="button" onClick={() => setFlash(null)} className="ml-3 text-xs underline opacity-70">fechar</button>
  </div>
}
