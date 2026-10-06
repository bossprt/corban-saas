import { redirect } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { isPortalUser } from '@/lib/portal'
import { can } from '@/lib/access'
import { OwnerDashboard, PERIODS, type PeriodKey } from './OwnerDashboard'
import { OperatorDashboard } from './OperatorDashboard'

// Visão geral (06/10/2026): finance (owner, manager, finance) gets the money dashboard; everyone else the operation of
// the day. Portal brokers have their own home.
export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ periodo?: string | string[] }> }) {
  const { supabase, organization, membership, user, access, modules } = await requireAppContext()
  if (isPortalUser(access?.roleKey, modules)) redirect('/app/portal')
  if (can(access, 'financeiro.view')) {
    const raw = (await searchParams).periodo
    const period = (typeof raw === 'string' && raw in PERIODS ? raw : 'mes') as PeriodKey
    return <OwnerDashboard supabase={supabase} organizationId={membership.organization_id} organizationName={organization?.name} period={period} />
  }
  return <OperatorDashboard supabase={supabase} organizationId={membership.organization_id} organizationName={organization?.name}
    onlyUserId={membership.role === 'agent' ? user.id : undefined} />
}
