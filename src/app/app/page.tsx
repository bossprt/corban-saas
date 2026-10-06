import Link from 'next/link'
import { redirect } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { isPortalUser } from '@/lib/portal'
import { can } from '@/lib/access'
import { OwnerDashboard, PERIODS, type PeriodKey } from './OwnerDashboard'
import { OperatorDashboard } from './OperatorDashboard'
import { SellerDashboard } from './SellerDashboard'

// Switch between the dashboard of the role and the person's own seller view, for whoever is linked to a seller record
// and is not only a seller (a manager or admin who also sells, 06/10/2026).
function ViewTabs({ seller }: { seller: boolean }) {
  const tab = (active: boolean) => `rounded-[9px] px-3 py-1.5 text-sm ${active ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted'}`
  return (
    <nav aria-label="Painel" className="mb-4 flex w-fit gap-1 rounded-[12px] border border-line bg-surface p-1">
      <Link href="/app" aria-current={!seller ? 'page' : undefined} className={tab(!seller)}>Visão geral</Link>
      <Link href="/app?visao=vendedor" aria-current={seller ? 'page' : undefined} className={tab(seller)}>Meu painel de vendedor</Link>
    </nav>
  )
}

// Visão geral (06/10/2026): finance (owner, manager, finance) gets the money dashboard; a seller their own month;
// everyone else the operation of the day. Portal brokers have their own home.
export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ periodo?: string | string[]; visao?: string | string[] }> }) {
  const { supabase, organization, membership, user, access, modules } = await requireAppContext()
  if (isPortalUser(access?.roleKey, modules)) redirect('/app/portal')
  const sp = await searchParams
  const { data: seller } = await supabase.from('commercial_sellers').select('id').eq('user_id', user.id).eq('is_active', true).limit(1).maybeSingle()
  // A plain seller (agent) sees their own month directly.
  if (seller && membership.role === 'agent') return <SellerDashboard supabase={supabase} organizationId={membership.organization_id} />
  const tabs = seller ? <ViewTabs seller={sp.visao === 'vendedor'} /> : null
  if (seller && sp.visao === 'vendedor') return <>{tabs}<SellerDashboard supabase={supabase} organizationId={membership.organization_id} /></>
  if (can(access, 'financeiro.view')) {
    const raw = sp.periodo
    const period = (typeof raw === 'string' && raw in PERIODS ? raw : 'mes') as PeriodKey
    return <>{tabs}<OwnerDashboard supabase={supabase} organizationId={membership.organization_id} organizationName={organization?.name} period={period} /></>
  }
  return <>{tabs}<OperatorDashboard supabase={supabase} organizationId={membership.organization_id} organizationName={organization?.name}
    onlyUserId={membership.role === 'agent' ? user.id : undefined} /></>
}
