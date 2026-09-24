'use client'

import { useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabaseClient'

export default function LoginForm({ notice }: { notice?: string }) {
  const router = useRouter()
  const [error, setError] = useState(notice ?? '')
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
    <main className="flex min-h-screen items-center justify-center bg-canvas px-4 py-10">
      <div className="w-full max-w-[400px]">
        <div className="mb-8 flex items-center gap-3">
          <div className="flex size-10 items-center justify-center rounded-xl bg-brand text-lg font-bold text-white" aria-hidden>C</div>
          <div>
            <h1 className="text-xl font-bold tracking-tight text-ink">Corban</h1>
            <p className="text-sm text-muted">Acesse sua operação</p>
          </div>
        </div>
        <form onSubmit={handleSubmit} className="space-y-5 rounded-[16px] border border-line bg-surface p-6 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
          <div>
            <label htmlFor="login-email" className="mb-1.5 block text-[13px] font-medium text-ink-soft">E-mail</label>
            <input id="login-email" name="email" type="email" autoComplete="email" required className="field h-11" />
          </div>
          <div>
            <div className="mb-1.5 flex items-center justify-between">
              <label htmlFor="login-password" className="block text-[13px] font-medium text-ink-soft">Senha</label>
              <Link href="/login/recuperar" className="text-[13px] text-brand hover:text-brand-strong">Esqueci minha senha</Link>
            </div>
            <input id="login-password" name="password" type="password" autoComplete="current-password" required className="field h-11" />
          </div>
          {error ? <p role="alert" className="rounded-lg bg-[#FDE2E1] px-3 py-2 text-sm text-[#991B1B]">{error}</p> : null}
          <button disabled={loading} type="submit" className="h-11 w-full rounded-[10px] bg-brand text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-60">
            {loading ? 'Entrando...' : 'Entrar'}
          </button>
        </form>
      </div>
    </main>
  )
}
