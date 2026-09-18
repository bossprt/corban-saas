'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'

export default function LoginPage() {
  const router = useRouter()
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    setLoading(true)

    const form = new FormData(event.currentTarget)
    const email = String(form.get('email') ?? '').trim()
    const password = String(form.get('password') ?? '')

    const { error: authError } = await supabase.auth.signInWithPassword({ email, password })
    setLoading(false)

    if (authError) {
      setError('Credenciais inválidas ou acesso indisponível.')
      return
    }

    router.replace('/app')
    router.refresh()
  }

  return (
    <main className="min-h-screen flex items-center justify-center bg-slate-900 px-4">
      <div className="max-w-md w-full bg-slate-800 rounded-xl shadow-2xl p-8 border border-slate-700">
        <div className="text-center mb-8">
          <h1 className="text-2xl font-bold text-white tracking-wide">Corban OS</h1>
          <p className="text-sm text-slate-400 mt-2">Acesse sua operação</p>
        </div>
        <form onSubmit={handleSubmit} className="space-y-6">
          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300 mb-2">E-mail</label>
            <input name="email" type="email" autoComplete="email" required className="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 text-white text-sm" />
          </div>
          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300 mb-2">Senha</label>
            <input name="password" type="password" autoComplete="current-password" required className="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 text-white text-sm" />
          </div>
          {error ? <p role="alert" className="text-sm text-red-300">{error}</p> : null}
          <button disabled={loading} type="submit" className="w-full bg-blue-600 hover:bg-blue-500 disabled:opacity-60 text-white font-medium py-3 rounded-lg text-sm">
            {loading ? 'Entrando...' : 'Entrar no Sistema'}
          </button>
        </form>
      </div>
    </main>
  )
}
