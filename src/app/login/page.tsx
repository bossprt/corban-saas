import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'

type LoginState = { error?: string }

async function login(_: LoginState, formData: FormData): Promise<LoginState> {
  'use server'

  const email = String(formData.get('email') ?? '').trim()
  const password = String(formData.get('password') ?? '')

  if (!email || !password) return { error: 'Informe e-mail e senha.' }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword({ email, password })

  if (error) return { error: 'Credenciais inválidas ou acesso indisponível.' }

  redirect('/app')
}

export default function LoginPage() {
  return (
    <main className="min-h-screen flex items-center justify-center bg-slate-900 px-4">
      <div className="max-w-md w-full bg-slate-800 rounded-xl shadow-2xl p-8 border border-slate-700">
        <div className="text-center mb-8">
          <h1 className="text-2xl font-bold text-white tracking-wide">Corban OS</h1>
          <p className="text-sm text-slate-400 mt-2">Acesse sua operação</p>
        </div>
        <form action={login.bind(null, {})} className="space-y-6">
          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300 mb-2">E-mail</label>
            <input name="email" type="email" autoComplete="email" required className="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 text-white text-sm" />
          </div>
          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300 mb-2">Senha</label>
            <input name="password" type="password" autoComplete="current-password" required className="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 text-white text-sm" />
          </div>
          <button type="submit" className="w-full bg-blue-600 hover:bg-blue-500 text-white font-medium py-3 rounded-lg text-sm">Entrar no Sistema</button>
        </form>
      </div>
    </main>
  )
}
