import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { selectOrganization } from './actions'

const ROLE: Record<string, string> = { admin: 'Administrador', manager: 'Gerente', supervisor: 'Supervisor', agent: 'Operador' }

export default async function OrganizationPickerPage({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')
  const { data: memberships } = await supabase.from('organization_memberships').select('organization_id, role').eq('user_id', user.id).eq('status', 'active')
  if (!memberships?.length) redirect('/access-pending')
  const ids = memberships.map(m => m.organization_id)
  const { data: orgs } = await supabase.from('organizations').select('id, name').in('id', ids)
  const name = new Map((orgs ?? []).map(o => [o.id, o.name]))
  const sp = await searchParams
  return <main className="flex min-h-screen items-center justify-center bg-slate-950 px-4 text-white">
    <section className="w-full max-w-lg rounded-xl border border-slate-800 bg-slate-900 p-8">
      <h1 className="text-xl font-semibold">Escolha a organização</h1>
      <p className="mt-2 text-sm text-slate-400">Sua conta pertence a mais de uma organização. Os dados de cada uma ficam isolados; escolha em qual você vai trabalhar agora.</p>
      {sp.erro && <p role="alert" className="mt-3 rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-200">Organização inválida ou sem vínculo ativo.</p>}
      <div className="mt-5 space-y-2">
        {memberships.map(m => <form key={m.organization_id} action={selectOrganization}>
          <input type="hidden" name="organization_id" value={m.organization_id} />
          <button className="flex w-full items-center justify-between rounded-lg border border-slate-700 px-4 py-3 text-left hover:border-emerald-400"><span>{name.get(m.organization_id) ?? 'Organização'}</span><span className="text-xs text-slate-400">{ROLE[m.role] ?? m.role}</span></button>
        </form>)}
      </div>
    </section>
  </main>
}
