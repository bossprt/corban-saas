import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { ACTION_LABEL, ACTIONS, MODULE_LABEL, MODULES, SCOPE_LABEL, SCOPES, TIER_LABEL, type Tier } from '@/lib/access'
import { canManageTeam } from '@/lib/rbac'
import { TEAM_ERROR_MESSAGES, TEAM_OK_MESSAGES, isTeamErrorCode, isTeamOkCode } from '@/lib/team'
import { Badge, Button, Card, PageHeader } from '@/components/ui'
import { saveRole } from './actions'

type RoleRow = { id: string; key: string; name: string; tier: Tier; scope: string; permissions: string[]; is_system: boolean; is_active: boolean }

const NEW = 'novo'

export default async function RolesPage({ searchParams }: { searchParams: Promise<{ papel?: string; erro?: string; ok?: string }> }) {
  const { supabase, membership } = await requireAppContext()
  const sp = await searchParams
  if (!canManageTeam(membership.role)) {
    return <section><PageHeader title="Papéis e permissões" /><Card className="p-5 text-sm text-ink-soft">Papéis e permissões são visíveis para administrador e gerente.</Card></section>
  }

  const { data, error } = await supabase.from('organization_roles').select('id,key,name,tier,scope,permissions,is_system,is_active').order('is_system', { ascending: false }).order('name')
  if (error) {
    return <section><PageHeader title="Papéis e permissões" /><Card className="p-5 text-sm text-ink-soft">Papéis ainda não estão disponíveis neste ambiente.</Card></section>
  }
  const roles = (data ?? []) as RoleRow[]
  const [{ data: members }] = await Promise.all([supabase.from('organization_memberships').select('role_id').eq('status', 'active')])
  const inUse = new Map<string, number>()
  for (const m of members ?? []) if (m.role_id) inUse.set(m.role_id, (inUse.get(m.role_id) ?? 0) + 1)

  const isAdmin = membership.role === 'admin'
  const selectedId = sp.papel === NEW && isAdmin ? NEW : roles.find(r => r.id === sp.papel)?.id ?? roles[0]?.id
  const selected = selectedId === NEW ? null : roles.find(r => r.id === selectedId) ?? null
  const editable = isAdmin && (selectedId === NEW || (selected !== null && selected.tier !== 'admin'))
  const granted = new Set(selected?.tier === 'admin' ? MODULES.flatMap(m => ACTIONS.map(a => `${m}.${a}`)) : selected?.permissions ?? [])

  return (
    <section>
      <PageHeader
        title="Papéis e permissões"
        description="Cada pessoa da equipe tem um papel. O papel define o que ela pode fazer em cada módulo e quais dados ela enxerga."
        actions={isAdmin ? <Link href={`?papel=${NEW}`} className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-medium text-white hover:bg-brand-strong">Novo papel</Link> : null}
      />
      {isTeamErrorCode(sp.erro) && <p role="alert" className="mb-4 rounded-lg bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">{TEAM_ERROR_MESSAGES[sp.erro]}</p>}
      {isTeamOkCode(sp.ok) && <p role="status" className="mb-4 rounded-lg bg-brand-soft px-4 py-3 text-sm text-brand-strong">{TEAM_OK_MESSAGES[sp.ok]}</p>}

      <div className="grid gap-4 lg:grid-cols-[280px_1fr]">
        <Card className="h-fit p-2">
          <nav aria-label="Papéis">
            {roles.map(r => (
              <Link key={r.id} href={`?papel=${r.id}`} aria-current={r.id === selectedId ? 'page' : undefined}
                className={`flex items-center justify-between gap-2 rounded-lg px-3 py-2.5 text-sm ${r.id === selectedId ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted'}`}>
                <span className="min-w-0 truncate">{r.name}{!r.is_active && <span className="ml-1 text-xs font-normal text-muted">(desativado)</span>}</span>
                <span className="num text-xs text-muted">{inUse.get(r.id) ?? 0}</span>
              </Link>
            ))}
          </nav>
        </Card>

        <Card className="p-5">
          <form action={saveRole} className="space-y-5">
            {selected && <input type="hidden" name="role_id" value={selected.id} />}
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="text-lg font-semibold text-ink">{selected ? selected.name : 'Novo papel'}</h2>
              {selected?.is_system && <Badge tone="neutral">Padrão</Badge>}
              {selected && <Badge tone="brand">{inUse.get(selected.id) ?? 0} membro(s)</Badge>}
            </div>
            {selected?.tier === 'admin' && <p className="text-sm text-muted">O Administrador tem acesso total e não pode ser alterado.</p>}

            <div className="grid gap-4 sm:grid-cols-3">
              <label className="block text-[13px] font-medium text-ink-soft">Nome
                <input name="name" required minLength={2} maxLength={60} defaultValue={selected?.name ?? ''} disabled={!editable} className="field mt-1.5" />
              </label>
              <label className="block text-[13px] font-medium text-ink-soft">Nível de acesso
                <select name="tier" defaultValue={selected?.tier ?? 'agent'} disabled={!editable || !!selected?.is_system} className="field mt-1.5">
                  {(['manager', 'supervisor', 'agent'] as const).map(t => <option key={t} value={t}>{TIER_LABEL[t]}</option>)}
                  {selected?.tier === 'admin' && <option value="admin">{TIER_LABEL.admin}</option>}
                </select>
                {selected?.is_system && <input type="hidden" name="tier" value={selected.tier} />}
              </label>
              <label className="block text-[13px] font-medium text-ink-soft">Enxerga os dados de
                <select name="scope" defaultValue={selected?.scope ?? 'own'} disabled={!editable} className="field mt-1.5">
                  {SCOPES.map(s => <option key={s} value={s}>{SCOPE_LABEL[s]}</option>)}
                </select>
              </label>
            </div>

            <div className="overflow-x-auto rounded-[12px] border border-line">
              <table className="w-full text-sm">
                <thead className="bg-surface-muted text-left text-xs font-semibold text-muted">
                  <tr><th className="px-4 py-2.5">Módulo</th>{ACTIONS.map(a => <th key={a} className="px-3 py-2.5 text-center">{ACTION_LABEL[a]}</th>)}</tr>
                </thead>
                <tbody>
                  {MODULES.map(m => (
                    <tr key={m} className="border-t border-line">
                      <td className="px-4 py-2.5 text-ink">{MODULE_LABEL[m]}</td>
                      {ACTIONS.map(a => {
                        const perm = `${m}.${a}`
                        return (
                          <td key={a} className="px-3 py-2.5 text-center">
                            <input type="checkbox" name="permissions" value={perm} defaultChecked={granted.has(perm)} disabled={!editable}
                              aria-label={`${ACTION_LABEL[a]} ${MODULE_LABEL[m]}`} className="size-4 accent-[var(--brand)]" />
                          </td>
                        )
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <p className="text-xs text-muted">
              O nível de acesso decide o que as telas antigas liberam enquanto elas migram para permissões. O alcance dos dados passa a valer na próxima etapa da F1.
            </p>

            {editable && (
              <div className="flex flex-wrap items-center gap-3">
                <Button type="submit">Salvar papel</Button>
                {selected && !selected.is_system && (
                  <label className="flex items-center gap-2 text-sm text-ink-soft">
                    <select name="is_active" defaultValue={selected.is_active ? 'true' : 'false'} className="field h-9 w-auto py-1">
                      <option value="true">Ativo</option>
                      <option value="false">Desativado</option>
                    </select>
                  </label>
                )}
              </div>
            )}
          </form>
        </Card>
      </div>
    </section>
  )
}
