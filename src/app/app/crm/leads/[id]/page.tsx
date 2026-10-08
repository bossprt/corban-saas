import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import type { SimulatorSp } from '@/app/app/simulacoes/SimulatorPanel'
import { LeadDetail, leadTab, type LeadTab } from '../../LeadDetail'

// The lead on its own page (links, old bookmarks). On the Vendas board the same view opens in the side panel.
export default async function LeadPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<SimulatorSp & { aba?: string }> }) {
  const ctx = await requireAppContext()
  if (!can(ctx.access, 'leads.view')) redirect('/app/hoje')
  const { id } = await params
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound()
  const sp = await searchParams
  const tab = leadTab(sp.aba)
  const href = (t: LeadTab) => `/app/crm/leads/${id}${t === 'resumo' ? '' : `?aba=${t}`}`
  return (
    <section>
      <Link href="/app/crm" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendas</Link>
      <LeadDetail id={id} tab={tab} sp={sp} href={href} keep={{}} />
    </section>
  )
}
