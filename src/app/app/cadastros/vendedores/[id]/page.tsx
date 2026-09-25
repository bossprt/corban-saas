import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { CATEGORY_LABEL, originText, sellerCode } from '@/lib/sellers'
import { isUuid } from '@/lib/team'
import { inviteSellerToPortal, saveSeller, setSellerActive } from '../actions'
import { SellerForm, type SellerValues } from '../SellerForm'
import type { SellerAccount, SellerContact } from '../SellerRows'

// The seller file is the registration form ("novo" registers a new seller), plus portal access and activation.
export default async function SellerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const isNew = id === 'novo'
  if (!isNew && !isUuid(id)) notFound()
  const { supabase, membership, access } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Vendedor" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  if (isNew && !canEdit) return <section><PageHeader title="Novo vendedor" /><Card className="p-5 text-sm text-ink-soft">Seu papel não cadastra vendedores.</Card></section>
  // Bank data: admin, manager and finance (the database enforces the same).
  const canSeeBank = canEdit || can(access, 'financeiro.view')

  const [{ data: groups }, { data: branches }, seller, profile, accounts, contacts] = await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('organization_branches').select('id,name,is_active').eq('is_active', true).order('name'),
    isNew ? Promise.resolve({ data: null }) : supabase.from('commercial_sellers').select('id,code,name,tax_id,seller_category,commission_group_id,branch_id,is_active,user_id,origin,imported_at').eq('id', id).maybeSingle(),
    isNew ? Promise.resolve({ data: null }) : supabase.from('seller_profiles').select('*').eq('seller_id', id).maybeSingle(),
    isNew || !canSeeBank ? Promise.resolve({ data: [] }) : supabase.from('seller_bank_accounts')
      .select('id,transfer_method,account_type,bank_code,bank_name,branch,account_number,account_digit,pix_key_type,pix_key,holder_name,holder_document,note,is_primary')
      .eq('seller_id', id).is('removed_at', null).order('is_primary', { ascending: false }).order('created_at'),
    isNew ? Promise.resolve({ data: [] }) : supabase.from('seller_contacts').select('name,cpf,role,mobile,email').eq('seller_id', id).order('created_at'),
  ])
  const s = seller.data
  if (!isNew && !s) notFound()
  const p = (profile.data ?? {}) as Record<string, string | null>
  const values: SellerValues | undefined = s ? {
    id: s.id, code: s.code, name: s.name, tax_id: s.tax_id, seller_category: s.seller_category, commission_group_id: s.commission_group_id, branch_id: s.branch_id,
    trade_name: p.trade_name ?? null, birth_or_opening_date: p.birth_or_opening_date ?? null, identity_or_registration_number: p.identity_or_registration_number ?? null,
    identity_issuer: p.identity_issuer ?? null, rg_issued_on: p.rg_issued_on ?? null, mother_name: p.mother_name ?? null, father_name: p.father_name ?? null,
    phone: p.phone ?? null, whatsapp: p.whatsapp ?? null, other_phones: p.other_phones ?? null, email: p.email ?? null,
    zip: p.zip ?? null, street: p.street ?? null, number: p.number ?? null, complement: p.complement ?? null, district: p.district ?? null, city: p.city ?? null, state: p.state ?? null,
    business_zip: p.business_zip ?? null, business_street: p.business_street ?? null, business_number: p.business_number ?? null, business_complement: p.business_complement ?? null,
    business_district: p.business_district ?? null, business_city: p.business_city ?? null, business_state: p.business_state ?? null,
  } : undefined
  const groupOptions = (groups ?? []).filter(g => g.is_active || g.id === s?.commission_group_id).map(g => ({ id: g.id, name: g.name }))
  const missing = s ? [!p.phone && 'celular', !p.email && 'e-mail', !(accounts.data ?? []).length && canSeeBank && 'dados para pagamento'].filter(Boolean) : []

  return (
    <section>
      <Link href="/app/cadastros/vendedores" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendedores</Link>
      <PageHeader
        title={s ? s.name : 'Novo vendedor'}
        description={s ? (
          <span className="flex flex-wrap items-center gap-2">
            <span className="font-mono">Código {sellerCode(s.code)}</span>
            <span>{CATEGORY_LABEL[s.seller_category] ?? s.seller_category}</span>
            <Badge tone={s.is_active ? 'received' : 'neutral'}>{s.is_active ? 'Ativo' : 'Inativo'}</Badge>
            {s.user_id && <Badge tone="brand">Com acesso ao portal</Badge>}
            {originText(s.origin, s.imported_at) && <span className="text-xs">{originText(s.origin, s.imported_at)}</span>}
            {missing.length > 0 && <><Badge tone="pending">Cadastro incompleto</Badge><span className="text-xs">Falta: {missing.join(', ')}.</span></>}
          </span>
        ) : 'O código do vendedor é gerado automaticamente ao cadastrar.'}
      />
      <Card className="p-5">
        <SellerForm key={s ? `${s.id}-${p.updated_at ?? ''}` : 'novo'} action={saveSeller} seller={values}
          accounts={(accounts.data ?? []) as SellerAccount[]} contacts={(contacts.data ?? []) as SellerContact[]}
          groups={groupOptions} branches={(branches ?? []).map(b => ({ id: b.id, name: b.name }))} canEdit={canEdit} canSeeBank={canSeeBank} />
      </Card>

      {s && canEdit && (
        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <Card>
            <CardHeader title="Acesso ao portal" />
            <div className="px-5 pb-5 pt-3 text-sm">
              {s.user_id ? <p className="text-ink-soft">Este vendedor já entra no portal do corretor.</p> : !s.is_active ? <p className="text-muted">Reative o vendedor para dar acesso.</p> : (
                <form action={inviteSellerToPortal} className="flex flex-wrap gap-2">
                  <input type="hidden" name="id" value={s.id} />
                  <input required name="email" type="email" defaultValue={p.email ?? ''} placeholder="E-mail do corretor" aria-label="E-mail do corretor" className="field max-w-xs" />
                  <SubmitButton className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Enviar convite</SubmitButton>
                </form>
              )}
              <p className="mt-2 text-xs text-muted">Entra com o papel Corretor: vê só as propostas e o extrato dele.</p>
            </div>
          </Card>
          <Card>
            <CardHeader title="Situação" />
            <form action={setSellerActive} className="flex items-center justify-between gap-3 px-5 pb-5 pt-3 text-sm">
              <span className="text-ink-soft">{s.is_active ? 'Ativo: aparece nas propostas e recebe comissão.' : 'Inativo: não aparece em propostas novas.'}</span>
              <input type="hidden" name="id" value={s.id} />
              <input type="hidden" name="active" value={s.is_active ? 'false' : 'true'} />
              <SubmitButton className="h-9 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink hover:bg-surface-muted">{s.is_active ? 'Inativar' : 'Reativar'}</SubmitButton>
            </form>
          </Card>
        </div>
      )}
    </section>
  )
}
