import Link from 'next/link'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { canManageMemberRole, canManageTeam, rolesAssignableBy } from '@/lib/rbac'
import { AUDIT_LABEL, INVITE_STATUS_LABEL, ROLE_LABEL, STATUS_LABEL, TEAM_ERROR_MESSAGES, TEAM_OK_MESSAGES, isTeamErrorCode, isTeamOkCode } from '@/lib/team'
import { memberEmails } from '@/lib/team.server'
import { changeMemberHierarchy, changeMemberRole, changeMemberStatus, createMemberAccess, resetMemberPassword, revokeInvitation } from './actions'
import { PasswordPair } from '@/components/PasswordPair'
import { SubmitButton } from '@/components/SubmitButton'
import { SCOPE_LABEL, SCOPES } from '@/lib/access'

const btn = 'inline-flex h-8 items-center rounded-[10px] border border-line bg-surface px-2.5 text-xs text-ink hover:bg-surface-muted'
const selectSm = 'rounded-[8px] border border-line-strong bg-surface px-2 py-1 text-xs text-ink outline-none focus:border-brand'
const ROLE_ORDER=['admin','manager','supervisor','agent']

export default async function TeamPage({ searchParams }: { searchParams: Promise<{ erro?: string; ok?: string }> }) {
  const { supabase, membership, organization, user } = await requireAppContext()
  const sp = await searchParams
  if (!canManageTeam(membership.role)) return <section>
    <PageHeader title="Equipe" />
    <Card className="p-5"><p role="alert" className="text-sm text-ink-soft">A gestão da equipe é restrita aos perfis administrador e gerente.</p></Card>
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
    <PageHeader title="Equipe" />
    <Card className="p-5"><p className="text-sm text-muted">A gestão de equipe ainda não está disponível neste ambiente (migration pendente de autorização).</p></Card>
  </section>
  const emails = await memberEmails((members.data ?? []).map(m => m.user_id))
  const assignable = rolesAssignableBy(membership.role)
  const roleName = new Map((roles.data ?? []).map(r => [r.id, r.name]))
  const rows = [...(members.data ?? [])].sort((a, b) => (a.status === 'active' ? 0 : 1) - (b.status === 'active' ? 0 : 1) || ROLE_ORDER.indexOf(a.role) - ROLE_ORDER.indexOf(b.role))
  const pending = (invitations.data ?? []).filter(i => i.status === 'pending' && new Date(i.expires_at) > new Date())
  const past = (invitations.data ?? []).filter(i => !pending.includes(i)).slice(0, 10)

  return <section>
    <PageHeader title="Equipe" description={<>{organization.name}: quem acessa esta organização e com qual papel (<Link href="/app/configuracao/papeis" className="text-brand hover:underline">ver papéis e permissões</Link>). Desativar um acesso bloqueia a pessoa imediatamente; o histórico é preservado.</>} />
    {isTeamErrorCode(sp.erro) && <p role="alert" className="mb-4 rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-3 text-sm text-[#92400E]">{TEAM_ERROR_MESSAGES[sp.erro]}</p>}
    {isTeamOkCode(sp.ok) && <p role="status" className="mb-4 rounded-[10px] border border-[#BBE5C8] bg-[#E3F5E9] px-4 py-3 text-sm text-[#15803D]">{TEAM_OK_MESSAGES[sp.ok]}</p>}

    <Card className="mt-2 p-4">
      <h2 className="mb-3 text-base font-semibold text-ink">Criar acesso</h2>
      <form action={createMemberAccess} className="flex flex-wrap items-end gap-3">
        <label className="text-xs text-muted">E-mail<input name="email" type="email" required maxLength={254} autoComplete="off" className="field mt-1 block w-72" /></label>
        <label className="text-xs text-muted">Perfil<select name="role" defaultValue="agent" className="field mt-1 block">{assignable.map(r => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}</select></label>
        <PasswordPair idPrefix="novo" />
        <label className="flex h-10 items-center gap-1.5 text-xs text-muted"><input type="checkbox" name="must_change" defaultChecked className="accent-[var(--brand)]" />Pedir nova senha no primeiro acesso</label>
        <SubmitButton pendingText="Criando..." className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Criar acesso</SubmitButton>
        <p className="w-full text-xs text-muted">A pessoa entra já com este e-mail e esta senha, sem esperar e-mail. Passe a senha para ela pessoalmente ou por um canal seu. O acesso vale só para esta empresa.</p>
      </form>
    </Card>

    <h2 className="mt-8 text-xl font-semibold text-ink">Membros</h2>
    {!rows.length ? <Card className="mt-3 p-5"><p className="text-sm text-muted">Nenhum membro.</p></Card> : <div className="mt-3 space-y-2">{rows.map(m => {
      const self = m.user_id === user.id
      const manageable = !self && canManageMemberRole(membership.role, m.role, m.role)
      return <Card key={m.id} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
        <div><strong className="text-ink">{emails.get(m.user_id) ?? 'Usuário'}</strong>{self && <span className="ml-2 text-xs text-muted">(você)</span>}
          <div className="mt-1 text-xs text-muted">{(m.role_id && roleName.get(m.role_id)) ?? ROLE_LABEL[m.role] ?? m.role} · <span className={m.status === 'active' ? 'text-[#15803D]' : 'text-[#92400E]'}>{STATUS_LABEL[m.status] ?? m.status}</span></div></div>
        {manageable && <div className="flex flex-wrap items-center gap-2">
          <form action={changeMemberRole} className="flex gap-1"><input type="hidden" name="membership_id" value={m.id} />
            <select name="role_id" defaultValue={m.role_id ?? ''} aria-label="Papel" className={selectSm}>{(roles.data ?? []).filter(r => canManageMemberRole(membership.role, m.role, r.tier)).map(r => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
            <button className={btn}>Alterar papel</button></form>
          <details className="w-full basis-full text-xs text-muted"><summary className="cursor-pointer">Filial, equipe e alcance</summary>
            <form action={changeMemberHierarchy} className="mt-2 flex flex-wrap items-end gap-2"><input type="hidden" name="membership_id" value={m.id} />
              <label>Filial<select name="branch_id" defaultValue={m.branch_id ?? ''} className={`${selectSm} mt-1 block`}><option value="">Sem filial</option>{(branches.data ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
              <label>Líder da equipe<select name="team_leader_user_id" defaultValue={m.team_leader_user_id ?? ''} className={`${selectSm} mt-1 block`}><option value="">Sem líder</option>{rows.filter(o => o.user_id !== m.user_id && o.status === 'active').map(o => <option key={o.user_id} value={o.user_id}>{emails.get(o.user_id) ?? 'Usuário'}</option>)}</select></label>
              <label>Enxerga<select name="scope_override" defaultValue={m.scope_override ?? ''} className={`${selectSm} mt-1 block`}><option value="">Conforme o papel</option>{SCOPES.filter(sc => sc !== 'all' || membership.role === 'admin').map(sc => <option key={sc} value={sc}>{SCOPE_LABEL[sc]}</option>)}</select></label>
              <button className={btn}>Salvar</button>
            </form>
          </details>
          <details className="w-full basis-full text-xs text-muted"><summary className="cursor-pointer">Redefinir senha</summary>
            <form action={resetMemberPassword} className="mt-2 flex flex-wrap items-end gap-2"><input type="hidden" name="membership_id" value={m.id} />
              <PasswordPair idPrefix={`reset-${m.id}`} label="Nova senha" />
              <label className="flex h-10 items-center gap-1.5"><input type="checkbox" name="must_change" defaultChecked className="accent-[var(--brand)]" />Pedir nova senha no próximo acesso</label>
              <SubmitButton pendingText="Salvando..." className={btn}>Salvar senha</SubmitButton>
            </form>
          </details>
          <form action={changeMemberStatus}><input type="hidden" name="membership_id" value={m.id} />
            {m.status === 'active'
              ? <><input type="hidden" name="status" value="inactive" /><button className={btn} title="Bloqueia o acesso imediatamente; pode ser reativado">Desativar acesso</button></>
              : <><input type="hidden" name="status" value="active" /><button className={btn}>Reativar acesso</button></>}</form>
        </div>}
      </Card>
    })}</div>}

    {pending.length > 0 && <><h2 className="mt-8 text-xl font-semibold text-ink">Convites por e-mail pendentes</h2>
    <p className="mt-1 text-sm text-muted">O convite por e-mail foi substituído. Para liberar a pessoa, crie o acesso com senha acima, com o mesmo e-mail; o convite antigo é trocado automaticamente.</p>
    <div className="mt-3 space-y-2">{pending.map(i => {
      const manageable = canManageMemberRole(membership.role, null, i.role)
      return <Card key={i.id} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
        <div><strong className="text-ink">{i.email}</strong><div className="mt-1 text-xs text-muted">{ROLE_LABEL[i.role] ?? i.role} · vence em {new Date(i.expires_at).toLocaleDateString('pt-BR')}</div></div>
        {manageable && <div className="flex gap-2">
          <form action={revokeInvitation}><input type="hidden" name="invitation_id" value={i.id} /><button className={btn}>Cancelar</button></form>
        </div>}
      </Card>
    })}</div></>}
    {past.length > 0 && <p className="mt-3 text-xs text-muted">Anteriores: {past.map(i => `${i.email} (${INVITE_STATUS_LABEL[i.status] ?? i.status})`).join(' · ')}</p>}

    <h2 className="mt-8 text-xl font-semibold text-ink">Últimas alterações</h2>
    {!events.data?.length ? <Card className="mt-3 p-5"><p className="text-sm text-muted">Nenhuma alteração registrada.</p></Card> : <ul className="mt-3 space-y-1 text-xs text-muted">{events.data.map(e => <li key={e.id}>{new Date(e.occurred_at).toLocaleString('pt-BR')} · {e.event_type === 'invite_created' && (e.details as { with_password?: boolean } | null)?.with_password ? 'Acesso criado com senha' : AUDIT_LABEL[e.event_type] ?? 'Alteração de configuração'}{e.target_email ? ` · ${e.target_email}` : ''}</li>)}</ul>}
  </section>
}
