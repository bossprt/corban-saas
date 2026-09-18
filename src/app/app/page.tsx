import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'

export default async function AppPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: memberships } = await supabase
    .from('organization_memberships')
    .select('organization_id, role, status')
    .eq('status', 'active')

  if (!memberships?.length) redirect('/access-pending')

  return (
    <main className="min-h-screen bg-slate-950 text-white p-8">
      <h1 className="text-2xl font-semibold">Corban OS</h1>
      <p className="mt-2 text-slate-400">Sessão autenticada e vínculo organizacional ativo.</p>
    </main>
  )
}
