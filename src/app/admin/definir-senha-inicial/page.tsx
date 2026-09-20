'use client'

import { FormEvent, useEffect, useState } from 'react'

const MIN_LENGTH = 12

export default function InitialPasswordPage() {
  const [token, setToken] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [state, setState] = useState<'checking' | 'ready' | 'saving' | 'done' | 'invalid' | 'error'>('checking')
  const [message, setMessage] = useState('')

  useEffect(() => {
    const value = window.location.hash.replace(/^#/, '').trim()
    window.history.replaceState(null, '', window.location.pathname)
    if (!value) {
      setState('invalid')
      return
    }
    setToken(value)
    setState('ready')
  }, [])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setMessage('')
    if (password.length < MIN_LENGTH) {
      setMessage(`Use ao menos ${MIN_LENGTH} caracteres.`)
      return
    }
    if (password !== confirm) {
      setMessage('As senhas não conferem.')
      return
    }

    setState('saving')
    try {
      const response = await fetch('/api/admin/definir-senha-inicial', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ token, password }),
        cache: 'no-store',
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        setMessage(typeof data?.error === 'string' ? data.error : 'Não foi possível definir a senha.')
        setState(response.status === 401 || response.status === 410 ? 'invalid' : 'error')
        return
      }
      setPassword('')
      setConfirm('')
      setToken('')
      setState('done')
    } catch {
      setMessage('Falha de conexão. Tente novamente.')
      setState('error')
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-900 px-4">
      <div className="w-full max-w-md rounded-xl border border-slate-700 bg-slate-800 p-8 shadow-2xl">
        <h1 className="text-2xl font-bold text-white">Definir senha</h1>
        <p className="mt-2 text-sm text-slate-400">Acesso temporário e de uso único para o administrador da Smart Promotora.</p>

        {state === 'checking' && <p className="mt-5 text-sm text-slate-300">Validando acesso...</p>}
        {state === 'invalid' && <p role="alert" className="mt-5 text-sm text-amber-200">{message || 'Este acesso é inválido ou já foi utilizado.'}</p>}
        {state === 'done' && (
          <div className="mt-5 space-y-4">
            <p className="text-sm text-emerald-300">Senha definida com sucesso.</p>
            <a href="/login" className="block w-full rounded-lg bg-blue-600 py-3 text-center text-sm font-medium text-white hover:bg-blue-500">Ir para o login</a>
          </div>
        )}

        {(state === 'ready' || state === 'saving' || state === 'error') && (
          <form onSubmit={submit} className="mt-6 space-y-5">
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300">
              Nova senha
              <input value={password} onChange={e => setPassword(e.target.value)} name="password" type="password" autoComplete="new-password" required minLength={MIN_LENGTH} maxLength={128} className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-900 px-4 py-3 text-sm text-white" />
            </label>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300">
              Repita a senha
              <input value={confirm} onChange={e => setConfirm(e.target.value)} name="confirm" type="password" autoComplete="new-password" required minLength={MIN_LENGTH} maxLength={128} className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-900 px-4 py-3 text-sm text-white" />
            </label>
            {message && <p role="alert" className="text-sm text-red-300">{message}</p>}
            <button disabled={state === 'saving'} type="submit" className="w-full rounded-lg bg-blue-600 py-3 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-60">{state === 'saving' ? 'Salvando...' : 'Definir senha'}</button>
          </form>
        )}
      </div>
    </main>
  )
}
