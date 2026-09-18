import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'

export default async function AccessPendingPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  return (
    <main className="min-h-screen flex items-center justify-center bg-slate-950 px-4 text-white">
      <section className="max-w-lg rounded-xl border border-slate-800 bg-slate-900 p-8">
        <h1 className="text-xl font-semibold">Acesso ainda não vinculado</h1>
        <p className="mt-3 text-sm text-slate-400">Sua conta está autenticada, mas não possui membership ativo em uma organização. O acesso aos dados permanece bloqueado.</p>
      </section>
    </main>
  )
}
