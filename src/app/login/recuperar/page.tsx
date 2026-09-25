import Link from 'next/link'
import { requestPasswordReset } from './actions'

export default async function RecoverPasswordPage({ searchParams }: { searchParams: Promise<{ erro?: string; enviado?: string }> }) {
  const sp = await searchParams
  return <main className="flex min-h-screen items-center justify-center bg-slate-900 px-4">
    <div className="w-full max-w-md rounded-xl border border-slate-700 bg-slate-800 p-8 shadow-2xl">
      <h1 className="text-2xl font-bold text-white">Recuperar senha</h1>
      {sp.enviado ? <p role="status" className="mt-4 text-sm text-slate-300">Se este e-mail tiver um acesso ao Corban OS, você receberá em instantes um link para criar uma nova senha. Confira também a caixa de spam.</p> : <form action={requestPasswordReset} className="mt-6 space-y-5">
        <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300">E-mail
          <input name="email" type="email" autoComplete="email" required maxLength={254} className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-900 px-4 py-3 text-sm text-white" /></label>
        {sp.erro === 'email' && <p role="alert" className="text-sm text-red-300">Informe um e-mail válido.</p>}
        <button type="submit" className="w-full rounded-lg bg-blue-600 py-3 text-sm font-medium text-white hover:bg-blue-500">Enviar link</button>
      </form>}
      <p className="mt-6 text-center text-xs"><Link href="/login" className="text-slate-400 underline hover:text-slate-200">Voltar ao login</Link></p>
    </div>
  </main>
}
