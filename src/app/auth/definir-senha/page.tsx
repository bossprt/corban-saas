'use client'

import { useEffect, useRef, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'
import { AuthShell, authButton, authError, authLabel } from '@/components/shell/AuthShell'

const MIN_LENGTH = 10

// First access after an invitation (or password recovery): the person chooses their own password.
// The session comes from the e-mail link (hash fragment handled by supabase-js, or the server-verified /auth/confirm redirect).
// We never see, store or log the link token; the password goes straight to Supabase Auth.
export default function SetPasswordPage() {
  const router = useRouter()
  const [state, setState] = useState<'checking' | 'ready' | 'invalid' | 'used'>('checking')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)
  const link = useRef<URLSearchParams | null>(null)

  useEffect(() => {
    let cancelled = false
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => { if (!cancelled && session) setState('ready') })
    // Links sent by Supabase Auth itself (invitation, admin recovery) bring the session in the fragment (#access_token=...).
    // The browser client runs the PKCE flow and ignores that format, so it is read here. The tokens are validated by
    // Supabase Auth in setSession and wiped from the address bar right away; never logged or stored by us.
    // Read once and kept in a ref: the effect may run twice (development), and the address is already clean the second time.
    if (link.current === null) {
      link.current = new URLSearchParams(window.location.hash.slice(1))
      if (window.location.hash) window.history.replaceState(null, '', window.location.pathname + window.location.search)
    }
    const hash = link.current
    const accessToken = hash.get('access_token'), refreshToken = hash.get('refresh_token')
    if (hash.get('error_code') === 'otp_expired') Promise.resolve().then(() => { if (!cancelled) setState('used') })
    else if (accessToken && refreshToken) {
      supabase.auth.setSession({ access_token: accessToken, refresh_token: refreshToken })
        .then(({ data, error: sessionError }) => { if (!cancelled) setState(!sessionError && data.session ? 'ready' : 'invalid') })
    } else {
      supabase.auth.getSession().then(({ data }) => { if (!cancelled && data.session) setState('ready') })
    }
    const timer = setTimeout(() => { if (!cancelled) setState(s => (s === 'checking' ? 'invalid' : s)) }, 6000)
    return () => { cancelled = true; clearTimeout(timer); sub.subscription.unsubscribe() }
  }, [])

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    const form = new FormData(event.currentTarget)
    const password = String(form.get('password') ?? '')
    const confirm = String(form.get('confirm') ?? '')
    if (password.length < MIN_LENGTH) return setError(`Use ao menos ${MIN_LENGTH} caracteres.`)
    if (password !== confirm) return setError('As senhas não conferem.')
    setSaving(true)
    const { error: updateError } = await supabase.auth.updateUser({ password })
    setSaving(false)
    if (updateError) return setError('Não foi possível salvar a senha. Peça um novo convite ou tente uma senha mais forte.')
    // A single navigation: the first entry accepts the pending invitation on the server (a concurrent refresh would find it
    // already accepted; /access-pending also sends an active member on to /app).
    router.replace('/app')
  }

  return (
    <AuthShell subtitle="Criar senha">
      {state === 'checking' && <p className="text-sm text-muted">Validando o seu link...</p>}
      {state === 'used' && <p role="alert" className={authError}>Este link já foi usado (cada link vale uma vez) ou expirou. Use &ldquo;Esqueci minha senha&rdquo; na tela de login com o mesmo e-mail para receber um novo.</p>}
      {state === 'invalid' && <p role="alert" className={authError}>Este link é inválido ou expirou. Peça um novo convite ao administrador, ou use &ldquo;Esqueci minha senha&rdquo; na tela de login.</p>}
      {state === 'ready' && (
        <form onSubmit={handleSubmit} className="space-y-5">
          <div>
            <label htmlFor="new-password" className={authLabel}>Nova senha <span className="font-normal text-muted">(mínimo {MIN_LENGTH} caracteres)</span></label>
            <input id="new-password" name="password" type="password" autoComplete="new-password" required minLength={MIN_LENGTH} className="field h-11" />
          </div>
          <div>
            <label htmlFor="confirm-password" className={authLabel}>Repita a senha</label>
            <input id="confirm-password" name="confirm" type="password" autoComplete="new-password" required minLength={MIN_LENGTH} className="field h-11" />
          </div>
          {error && <p role="alert" className={authError}>{error}</p>}
          <button disabled={saving} type="submit" className={authButton}>{saving ? 'Salvando...' : 'Salvar e entrar'}</button>
        </form>
      )}
    </AuthShell>
  )
}
