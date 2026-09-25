import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { acceptInvitationsFor } from '@/lib/team.server'
import { AuthShell, authError } from '@/components/shell/AuthShell'
import { selectOrganization } from './actions'

const ROLE: Record<string, string> = { admin: 'Administrador', manager: 'Gerente', supervisor: 'Supervisor', agent: 'Operador' }

export default async function OrganizationPickerPage({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')
  await acceptInvitationsFor(user) // an existing user invited to a second organization sees it here
  const { data: memberships } = await supabase.from('organization_memberships').select('organization_id, role').eq('user_id', user.id).eq('status', 'active')
  if (!memberships?.length) redirect('/access-pending')
  const ids = memberships.map(m => m.organization_id)
  const { data: orgs } = await supabase.from('organizations').select('id, name').in('id', ids)
  const name = new Map((orgs ?? []).map(o => [o.id, o.name]))
  const sp = await searchParams
  return (
    <AuthShell subtitle="Escolha a empresa">
      <p className="text-sm text-ink-soft">Sua conta pertence a mais de uma empresa. Os dados de cada uma ficam separados; escolha em qual você vai trabalhar agora.</p>
      {sp.erro && <p role="alert" className={`mt-3 ${authError}`}>Empresa inválida ou sem vínculo ativo.</p>}
      <div className="mt-5 space-y-2">
        {memberships.map(m => (
          <form key={m.organization_id} action={selectOrganization}>
            <input type="hidden" name="organization_id" value={m.organization_id} />
            <button className="flex w-full items-center justify-between rounded-[10px] border border-line bg-surface px-4 py-3 text-left text-sm text-ink hover:border-brand hover:bg-surface-muted">
              <span className="font-medium">{name.get(m.organization_id) ?? 'Empresa'}</span><span className="text-xs text-muted">{ROLE[m.role] ?? m.role}</span>
            </button>
          </form>
        ))}
      </div>
    </AuthShell>
  )
}
