'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'

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

  return <main className="flex min-h-screen items-center justify-center bg-slate-900 px-4">
    <div className="w-full max-w-md rounded-xl border border-slate-700 bg-slate-800 p-8 shadow-2xl">
      <h1 className="text-2xl font-bold text-white">Criar senha</h1>
      {state === 'checking' && <p className="mt-4 text-sm text-slate-400">Validando o seu convite...</p>}
      {state === 'invalid' && <p role="alert" className="mt-4 text-sm text-amber-200">Este link é inválido ou expirou. Peça ao administrador da sua organização para reenviar o convite.</p>}
      {state === 'ready' && <form onSubmit={handleSubmit} className="mt-6 space-y-5">
        <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300">Nova senha
          <input name="password" type="password" autoComplete="new-password" required minLength={MIN_LENGTH} className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-900 px-4 py-3 text-sm text-white" /></label>
        <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300">Repita a senha
          <input name="confirm" type="password" autoComplete="new-password" required minLength={MIN_LENGTH} className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-900 px-4 py-3 text-sm text-white" /></label>
        {error && <p role="alert" className="text-sm text-red-300">{error}</p>}
        <button disabled={saving} type="submit" className="w-full rounded-lg bg-blue-600 py-3 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-60">{saving ? 'Salvando...' : 'Salvar e entrar'}</button>
      </form>}
    </div>
  </main>
}
