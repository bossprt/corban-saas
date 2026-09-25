'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'
import { AuthShell, authButton, authError, authLabel } from '@/components/shell/AuthShell'

const MIN_LENGTH = 10

// First access after an invitation (or password recovery): the person chooses their own password.
// The session comes from the e-mail link (hash fragment handled by supabase-js, or the server-verified /auth/confirm redirect).
// We never see, store or log the link token; the password goes straight to Supabase Auth.
export default function SetPasswordPage() {
  const router = useRouter()
  const [state, setState] = useState<'checking' | 'ready' | 'invalid'>('checking')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    let cancelled = false
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => { if (!cancelled && session) setState('ready') })
    supabase.auth.getSession().then(({ data }) => { if (!cancelled && data.session) setState('ready') })
    const timer = setTimeout(() => { if (!cancelled) setState(s => (s === 'checking' ? 'invalid' : s)) }, 4000)
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
    router.replace('/app')
    router.refresh()
  }

  return (
    <AuthShell subtitle="Criar senha">
      {state === 'checking' && <p className="text-sm text-muted">Validando o seu link...</p>}
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
