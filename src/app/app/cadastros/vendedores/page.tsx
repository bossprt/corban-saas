import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createSeller, inviteSellerToPortal, setSellerActive, updateSeller } from './actions'

const lbl = 'text-[13px] font-medium text-ink-soft'
const primary = 'h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost = 'h-9 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink hover:bg-surface-muted'
const CAT: Record<string, string> = { pf: 'PF', pj: 'PJ', sub: 'SUB' }

// Sellers: each one belongs to one seller group and is paid by that group's rule (owner decision 25/09/2026).
export default async function SellersPage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Vendedores" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const [groups, sellers] = await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commercial_sellers').select('id,name,seller_category,tax_id,commission_group_id,is_active,user_id').order('name'),
  ])
  const groupName = new Map((groups.data ?? []).map(x => [x.id, x.name]))
  const groupOptions = (current?: string) => (groups.data ?? []).filter(x => x.is_active || x.id === current).map(x => <option key={x.id} value={x.id}>{x.name}</option>)

  return (
    <section>
      <Link href="/app/cadastros" className="mb-3 inline-block text-sm text-muted hover:text-ink">← Cadastros</Link>
      <PageHeader title="Vendedores" description={<>Cada vendedor pertence a um <Link href="/app/comercial/grupos" className="text-brand hover:text-brand-strong">grupo de vendedores</Link> e recebe pela regra desse grupo.</>} />

      {canEdit && (
        <Card className="mb-4 p-5">
          <form action={createSeller} className="grid gap-3 md:grid-cols-4">
            <label className={`${lbl} md:col-span-2`}>Nome / razão social<input required name="name" maxLength={160} className="field mt-1.5" /></label>
            <label className={lbl}>CPF/CNPJ <span className="text-xs font-normal text-muted">opcional</span><input name="tax_id" inputMode="numeric" className="field mt-1.5" /></label>
            <label className={lbl}>Categoria<select required name="seller_category" defaultValue="" className="field mt-1.5"><option value="" disabled>—</option><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select></label>
            <label className={`${lbl} md:col-span-2`}>Grupo<select required name="commission_group_id" defaultValue="" className="field mt-1.5"><option value="" disabled>Escolha o grupo</option>{groupOptions()}</select></label>
            <div className="flex items-end md:col-span-2 md:justify-end"><SubmitButton className={primary}>Cadastrar vendedor</SubmitButton></div>
          </form>
        </Card>
      )}

      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Vendedores <Badge tone="neutral">{sellers.data?.length ?? 0}</Badge></span>} />
        <ul className="mt-3">
          {!(sellers.data ?? []).length && <li className="border-t border-line px-5 py-4 text-sm text-muted">Nenhum vendedor cadastrado.</li>}
          {(sellers.data ?? []).map(s => (
            <li key={s.id} className="border-t border-line px-5 py-3">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <span className="text-sm font-semibold text-ink">{s.name}</span>
                  <span className="block text-[13px] text-ink-soft">{CAT[s.seller_category] ?? s.seller_category} · Grupo: {groupName.get(s.commission_group_id) ?? '—'}</span>
                </div>
                <span className="flex items-center gap-2">{s.user_id && <Badge tone="brand">Com acesso</Badge>}<Badge tone={s.is_active ? 'received' : 'neutral'}>{s.is_active ? 'Ativo' : 'Inativo'}</Badge></span>
              </div>
              {canEdit && (
                <div className="mt-2 flex flex-wrap items-start gap-4">
                  <details>
                    <summary className="cursor-pointer text-xs text-brand">Editar cadastro</summary>
                    <form action={updateSeller} className="mt-2 grid gap-2 md:grid-cols-2">
                      <input type="hidden" name="id" value={s.id} />
                      <label className={lbl}>Nome<input required name="name" defaultValue={s.name} className="field mt-1" /></label>
                      <label className={lbl}>CPF/CNPJ<input name="tax_id" defaultValue={s.tax_id ?? ''} className="field mt-1" /></label>
                      <label className={lbl}>Categoria<select name="seller_category" defaultValue={s.seller_category} className="field mt-1"><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select></label>
                      <label className={lbl}>Grupo<select name="commission_group_id" defaultValue={s.commission_group_id} className="field mt-1">{groupOptions(s.commission_group_id)}</select></label>
                      <div><SubmitButton className={ghost}>Salvar</SubmitButton></div>
                    </form>
                  </details>
                  {s.is_active && !s.user_id && (
                    <details>
                      <summary className="cursor-pointer text-xs text-brand">Dar acesso ao portal</summary>
                      <form action={inviteSellerToPortal} className="mt-2 flex flex-wrap gap-2">
                        <input type="hidden" name="id" value={s.id} />
                        <input required name="email" type="email" placeholder="E-mail do corretor" aria-label="E-mail do corretor" className="field" />
                        <SubmitButton className={primary}>Enviar convite</SubmitButton>
                      </form>
                      <p className="mt-1 text-xs text-muted">Entra com o papel Corretor: vê só as propostas e o extrato dele.</p>
                    </details>
                  )}
                  <form action={setSellerActive}>
                    <input type="hidden" name="id" value={s.id} />
                    <input type="hidden" name="active" value={s.is_active ? 'false' : 'true'} />
                    <SubmitButton className="text-xs text-muted underline hover:text-ink">{s.is_active ? 'Inativar' : 'Reativar'}</SubmitButton>
                  </form>
                </div>
              )}
            </li>
          ))}
        </ul>
      </Card>
    </section>
  )
}
