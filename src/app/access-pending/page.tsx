import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { acceptInvitationsFor } from '@/lib/team.server'
import { signOut } from '@/app/app/actions'
import { Card } from '@/components/ui'

// Landing for an authenticated identity that has no ACTIVE membership. Access stays closed, with one exception: a pending, unexpired
// invitation addressed to this person's VERIFIED e-mail is accepted here (governed RPC, service role, identity from Auth).
export default async function AccessPendingPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const joined = await acceptInvitationsFor(user)
  if (joined > 0) redirect('/app')
  // Accepted by a concurrent request (or reactivated meanwhile): access is already open.
  const { data: active } = await supabase.from('organization_memberships').select('id').eq('user_id', user.id).eq('status', 'active').limit(1)
  if (active?.length) redirect('/app')

  return (
    <main className="flex min-h-screen items-center justify-center bg-canvas px-4">
      <Card className="max-w-lg p-8">
        <h1 className="text-xl font-semibold text-ink">Acesso ainda não liberado</h1>
        <p className="mt-3 text-sm text-muted">Você entrou como <strong className="text-ink-soft">{user.email}</strong>, mas esta conta não tem acesso ativo a nenhuma organização.</p>
        <ul className="mt-3 list-disc space-y-1 pl-5 text-sm text-muted">
          <li>Se você acabou de ser convidado, peça ao administrador para reenviar o convite e entre com o e-mail convidado.</li>
          <li>Se o seu acesso foi desativado, fale com o administrador da organização.</li>
        </ul>
        <div className="mt-6 flex gap-3">
          <a href="/access-pending" className="h-10 rounded-[10px] border border-line bg-surface px-4 py-2 text-sm hover:bg-surface-muted">Verificar novamente</a>
          <form action={signOut}><button className="rounded-[10px] px-4 py-2 text-sm text-muted hover:bg-surface-muted hover:text-ink">Sair</button></form>
        </div>
      </Card>
    </main>
  )
}
