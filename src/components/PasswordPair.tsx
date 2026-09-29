'use client'

import { useState } from 'react'

// Password typed by the admin for someone else (team access): shown on request so it can be checked before passing it on.
// Never stored in the page; the form posts it once to the server, which hands it to Supabase Auth.
export function PasswordPair({ idPrefix, label = 'Senha' }: { idPrefix: string; label?: string }) {
  const [show, setShow] = useState(false)
  const type = show ? 'text' : 'password'
  return (
    <>
      <label className="text-xs text-muted" htmlFor={`${idPrefix}-password`}>{label}
        <input id={`${idPrefix}-password`} name="password" type={type} required minLength={10} maxLength={72} autoComplete="new-password" className="field mt-1 block w-52" />
      </label>
      <label className="text-xs text-muted" htmlFor={`${idPrefix}-confirm`}>Repita a senha
        <input id={`${idPrefix}-confirm`} name="password_confirm" type={type} required minLength={10} maxLength={72} autoComplete="new-password" className="field mt-1 block w-52" />
      </label>
      <label className="flex h-10 items-center gap-1.5 text-xs text-muted">
        <input type="checkbox" checked={show} onChange={e => setShow(e.target.checked)} className="accent-[var(--brand)]" />Mostrar senha
      </label>
    </>
  )
}
