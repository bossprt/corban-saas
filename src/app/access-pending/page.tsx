import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { acceptInvitationsFor } from '@/lib/team.server'
import { signOut } from '@/app/app/actions'

// Landing for an authenticated identity that has no ACTIVE membership. Access stays closed, with one exception: a pending, unexpired
// invitation addressed to this person's VERIFIED e-mail is accepted here (governed RPC, service role, identity from Auth).
export default async function AccessPendingPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const joined = await acceptInvitationsFor(user)
  if (joined > 0) redirect('/app')

  return (
    <main className="min-h-screen flex items-center justify-center bg-slate-950 px-4 text-white">
      <section className="max-w-lg rounded-xl border border-slate-800 bg-slate-900 p-8">
        <h1 className="text-xl font-semibold">Acesso ainda não liberado</h1>
        <p className="mt-3 text-sm text-slate-400">Você entrou como <strong className="text-slate-200">{user.email}</strong>, mas esta conta não tem acesso ativo a nenhuma organização.</p>
        <ul className="mt-3 list-disc space-y-1 pl-5 text-sm text-slate-400">
          <li>Se você acabou de ser convidado, peça ao administrador para reenviar o convite e entre com o e-mail convidado.</li>
          <li>Se o seu acesso foi desativado, fale com o administrador da organização.</li>
        </ul>
        <div className="mt-6 flex gap-3">
          <a href="/access-pending" className="rounded-lg border border-slate-700 px-4 py-2 text-sm hover:border-slate-500">Verificar novamente</a>
          <form action={signOut}><button className="rounded-lg px-4 py-2 text-sm text-slate-400 hover:bg-slate-800 hover:text-white">Sair</button></form>
        </div>
      </section>
    </main>
  )
}
