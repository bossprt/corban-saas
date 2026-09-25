import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { canManageMemberRole, canManageTeam, rolesAssignableBy } from '@/lib/rbac'
import { AUDIT_LABEL, INVITE_STATUS_LABEL, ROLE_LABEL, STATUS_LABEL, TEAM_ERROR_MESSAGES, TEAM_OK_MESSAGES, isTeamErrorCode, isTeamOkCode } from '@/lib/team'
import { memberEmails } from '@/lib/team.server'
import { changeMemberHierarchy, changeMemberRole, changeMemberStatus, inviteMember, resendInvitation, revokeInvitation } from './actions'
import { SCOPE_LABEL, SCOPES } from '@/lib/access'

const btn='rounded border border-slate-700 px-2 py-1 text-xs hover:border-slate-500'
const ROLE_ORDER=['admin','manager','supervisor','agent']

export default async function TeamPage({ searchParams }: { searchParams: Promise<{ erro?: string; ok?: string }> }) {
  const { supabase, membership, organization, user } = await requireAppContext()
  const sp = await searchParams
  if (!canManageTeam(membership.role)) return <section>
    <h1 className="text-3xl font-semibold">Equipe</h1>
    <p role="alert" className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-300">A gestão da equipe é restrita aos perfis administrador e gerente.</p>
  </section>

  const [members, branches, roles, invitations, events] = await Promise.all([
    supabase.from('organization_memberships').select('id,user_id,role,role_id,status,created_at,branch_id,team_leader_user_id,scope_override').order('created_at'),
    supabase.from('organization_branches').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_roles').select('id,name,tier,is_active').eq('is_active', true).order('is_system', { ascending: false }).order('name'),
    supabase.from('organization_invitations').select('id,email,role,status,expires_at,created_at').order('created_at', { ascending: false }).limit(50),
    supabase.from('organization_admin_events').select('id,event_type,target_email,details,occurred_at').order('occurred_at', { ascending: false }).limit(15),
  ])
  // Migration not applied yet in this environment: say so instead of showing an empty team.
  if (invitations.error || events.error) return <section>
    <h1 className="text-3xl font-semibold">Equipe</h1>
    <p className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">A gestão de equipe ainda não está disponível neste ambiente (migration pendente de autorização).</p>
  </section>
  const emails = await memberEmails((members.data ?? []).map(m => m.user_id))
  const assignable = rolesAssignableBy(membership.role)
  const roleName = new Map((roles.data ?? []).map(r => [r.id, r.name]))
  const rows = [...(members.data ?? [])].sort((a, b) => (a.status === 'active' ? 0 : 1) - (b.status === 'active' ? 0 : 1) || ROLE_ORDER.indexOf(a.role) - ROLE_ORDER.indexOf(b.role))
  const pending = (invitations.data ?? []).filter(i => i.status === 'pending' && new Date(i.expires_at) > new Date())
  const past = (invitations.data ?? []).filter(i => !pending.includes(i)).slice(0, 10)

  return <section>
    <h1 className="text-3xl font-semibold">Equipe</h1>
    <p className="mt-2 text-sm text-slate-400">{organization.name}: quem acessa esta organização e com qual papel (<Link href="/app/configuracao/papeis" className="underline">ver papéis e permissões</Link>). Desativar um acesso bloqueia a pessoa imediatamente; o histórico é preservado.</p>
    {isTeamErrorCode(sp.erro) && <p role="alert" className="mt-4 rounded-xl border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-200">{TEAM_ERROR_MESSAGES[sp.erro]}</p>}
    {isTeamOkCode(sp.ok) && <p role="status" className="mt-4 rounded-xl border border-emerald-500/40 bg-emerald-500/10 p-3 text-sm text-emerald-200">{TEAM_OK_MESSAGES[sp.ok]}</p>}

    <form action={inviteMember} className="mt-6 flex flex-wrap items-end gap-3 rounded-xl border border-slate-800 bg-slate-900 p-4">
      <label className="text-xs text-slate-400">E-mail<input name="email" type="email" required maxLength={254} autoComplete="off" className="mt-1 block w-72 rounded border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-white" /></label>
      <label className="text-xs text-slate-400">Perfil<select name="role" defaultValue="agent" className="mt-1 block rounded border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-white">{assignable.map(r => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}</select></label>
      <button className="rounded bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Convidar</button>
      <p className="w-full text-xs text-slate-500">A pessoa recebe um e-mail para criar a senha. O convite vale por 7 dias e só dá acesso a esta organização.</p>
    </form>

    <h2 className="mt-8 text-xl font-semibold">Membros</h2>
    {!rows.length ? <p className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">Nenhum membro.</p> : <div className="mt-3 space-y-2">{rows.map(m => {
      const self = m.user_id === user.id
      const manageable = !self && canManageMemberRole(membership.role, m.role, m.role)
      return <div key={m.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm">
        <div><strong>{emails.get(m.user_id) ?? 'Usuário'}</strong>{self && <span className="ml-2 text-xs text-slate-500">(você)</span>}
          <div className="mt-1 text-xs text-slate-400">{(m.role_id && roleName.get(m.role_id)) ?? ROLE_LABEL[m.role] ?? m.role} · <span className={m.status === 'active' ? 'text-emerald-400' : 'text-amber-300'}>{STATUS_LABEL[m.status] ?? m.status}</span></div></div>
        {manageable && <div className="flex flex-wrap items-center gap-2">
          <form action={changeMemberRole} className="flex gap-1"><input type="hidden" name="membership_id" value={m.id} />
            <select name="role_id" defaultValue={m.role_id ?? ''} aria-label="Papel" className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs">{(roles.data ?? []).filter(r => canManageMemberRole(membership.role, m.role, r.tier)).map(r => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
            <button className={btn}>Alterar papel</button></form>
          <details className="w-full basis-full text-xs text-slate-400"><summary className="cursor-pointer">Filial, equipe e alcance</summary>
            <form action={changeMemberHierarchy} className="mt-2 flex flex-wrap items-end gap-2"><input type="hidden" name="membership_id" value={m.id} />
              <label>Filial<select name="branch_id" defaultValue={m.branch_id ?? ''} className="mt-1 block rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs"><option value="">Sem filial</option>{(branches.data ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
              <label>Líder da equipe<select name="team_leader_user_id" defaultValue={m.team_leader_user_id ?? ''} className="mt-1 block rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs"><option value="">Sem líder</option>{rows.filter(o => o.user_id !== m.user_id && o.status === 'active').map(o => <option key={o.user_id} value={o.user_id}>{emails.get(o.user_id) ?? 'Usuário'}</option>)}</select></label>
              <label>Enxerga<select name="scope_override" defaultValue={m.scope_override ?? ''} className="mt-1 block rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs"><option value="">Conforme o papel</option>{SCOPES.filter(sc => sc !== 'all' || membership.role === 'admin').map(sc => <option key={sc} value={sc}>{SCOPE_LABEL[sc]}</option>)}</select></label>
              <button className={btn}>Salvar</button>
            </form>
          </details>
          <form action={changeMemberStatus}><input type="hidden" name="membership_id" value={m.id} />
            {m.status === 'active'
              ? <><input type="hidden" name="status" value="inactive" /><button className={btn} title="Bloqueia o acesso imediatamente; pode ser reativado">Desativar acesso</button></>
              : <><input type="hidden" name="status" value="active" /><button className={btn}>Reativar acesso</button></>}</form>
        </div>}
      </div>
    })}</div>}

    <h2 className="mt-8 text-xl font-semibold">Convites pendentes</h2>
    {!pending.length ? <p className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">Nenhum convite pendente.</p> : <div className="mt-3 space-y-2">{pending.map(i => {
      const manageable = canManageMemberRole(membership.role, null, i.role)
      return <div key={i.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm">
        <div><strong>{i.email}</strong><div className="mt-1 text-xs text-slate-400">{ROLE_LABEL[i.role] ?? i.role} · vence em {new Date(i.expires_at).toLocaleDateString('pt-BR')}</div></div>
        {manageable && <div className="flex gap-2">
          <form action={resendInvitation}><input type="hidden" name="invitation_id" value={i.id} /><button className={btn}>Reenviar</button></form>
          <form action={revokeInvitation}><input type="hidden" name="invitation_id" value={i.id} /><button className={btn}>Cancelar</button></form>
        </div>}
      </div>
    })}</div>}
    {past.length > 0 && <p className="mt-3 text-xs text-slate-500">Anteriores: {past.map(i => `${i.email} (${INVITE_STATUS_LABEL[i.status] ?? i.status})`).join(' · ')}</p>}

    <h2 className="mt-8 text-xl font-semibold">Últimas alterações</h2>
    {!events.data?.length ? <p className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">Nenhuma alteração registrada.</p> : <ul className="mt-3 space-y-1 text-xs text-slate-400">{events.data.map(e => <li key={e.id}>{new Date(e.occurred_at).toLocaleString('pt-BR')} · {AUDIT_LABEL[e.event_type] ?? e.event_type}{e.target_email ? ` · ${e.target_email}` : ''}</li>)}</ul>}
  </section>
}
