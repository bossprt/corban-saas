import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { DISTRIBUTION_LABEL, isDistribution } from '@/lib/crm'
import { leadOwners } from '@/lib/crm.server'
import { saveCampaign } from '../actions'
import { CampaignFields } from './CampaignFields'
import { TemplateDownload } from './TemplateDownload'

const pct = (a: number, b: number) => (b > 0 ? `${Math.round((a / b) * 100)}%` : '—')
const day = (d: string | null) => (d ? d.split('-').reverse().join('/') : null)

// Campaigns: each spreadsheet the company works becomes a campaign with its sellers and distribution.
export default async function CampaignsPage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'leads.approve')) redirect('/app/crm')
  const [{ data: campaigns }, { data: counts }, people] = await Promise.all([
    supabase.from('sales_campaigns').select('id,name,distribution,starts_on,ends_on,status,created_at').order('status').order('created_at', { ascending: false }),
    supabase.rpc('sales_lead_counts', { p_org: organization.id }),
    leadOwners(supabase),
  ])
  const stats = new Map<string, { total: number; open: number; waiting: number; proposal: number; won: number; lost: number }>()
  for (const c of (counts ?? []) as { campaign_id: string | null; owner_user_id: string | null; status: string; total: number }[]) {
    if (!c.campaign_id) continue
    const s = stats.get(c.campaign_id) ?? { total: 0, open: 0, waiting: 0, proposal: 0, won: 0, lost: 0 }
    const n = Number(c.total)
    s.total += n
    if (['new', 'contacted', 'negotiating'].includes(c.status)) { s.open += n; if (!c.owner_user_id) s.waiting += n }
    if (c.status === 'proposal') s.proposal += n
    if (c.status === 'won') s.won += n
    if (c.status === 'lost') s.lost += n
    stats.set(c.campaign_id, s)
  }

  return (
    <section>
      <Link href="/app/crm" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendas</Link>
      <PageHeader title="Campanhas" description="Cada planilha de clientes vira uma campanha: crie a campanha, depois suba a planilha dentro dela." actions={<TemplateDownload />} />

      <Card className="mb-6 overflow-hidden">
        <CardHeader title="Campanhas" />
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[920px] text-left text-sm">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr><th className="px-5 py-2 font-medium">Campanha</th><th className="px-3 py-2 font-medium">Distribuição</th><th className="px-3 py-2 text-right font-medium">Leads</th><th className="px-3 py-2 text-right font-medium">Sem vendedor</th><th className="px-3 py-2 text-right font-medium">Em aberto</th><th className="px-3 py-2 text-right font-medium">Proposta</th><th className="px-3 py-2 text-right font-medium">Ganhos</th><th className="px-3 py-2 text-right font-medium">Conversão</th><th className="px-5 py-2" /></tr>
            </thead>
            <tbody>
              {(campaigns ?? []).map(c => {
                const s = stats.get(c.id) ?? { total: 0, open: 0, waiting: 0, proposal: 0, won: 0, lost: 0 }
                const period = [day(c.starts_on), day(c.ends_on)].filter(Boolean).join(' a ')
                return (
                  <tr key={c.id} className="border-t border-line hover:bg-surface-muted/60">
                    <td className="px-5 py-2.5">
                      <Link href={`/app/crm/campanhas/${c.id}`} className="font-medium text-ink hover:text-brand">{c.name}</Link>
                      {c.status === 'closed' && <Badge tone="neutral" className="ml-2">Encerrada</Badge>}
                      {period && <span className="block text-xs text-muted">{period}</span>}
                    </td>
                    <td className="px-3 py-2.5 text-ink-soft">{isDistribution(c.distribution) ? DISTRIBUTION_LABEL[c.distribution].split(':')[0] : c.distribution}</td>
                    <td className="num px-3 py-2.5 text-right">{s.total}</td>
                    <td className="num px-3 py-2.5 text-right">{s.waiting}</td>
                    <td className="num px-3 py-2.5 text-right">{s.open}</td>
                    <td className="num px-3 py-2.5 text-right">{s.proposal}</td>
                    <td className="num px-3 py-2.5 text-right font-medium text-ink">{s.won}</td>
                    <td className="num px-3 py-2.5 text-right">{pct(s.won, s.total)}</td>
                    <td className="px-5 py-2.5 text-right">{c.status === 'active' && <Link href={`/app/crm/campanhas/${c.id}#planilha`} className="inline-flex h-8 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Subir planilha</Link>}</td>
                  </tr>
                )
              })}
              {!campaigns?.length && <tr><td colSpan={9} className="px-5 py-10 text-center text-muted">Nenhuma campanha ainda. Crie a primeira abaixo e suba a planilha.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>

      <Card className="p-5">
        <h2 className="mb-4 text-base font-semibold text-ink">Nova campanha</h2>
        <form action={saveCampaign}>
          <CampaignFields lockedAtStart={false} people={people} values={{ name: '', description: null, distribution: 'queue', starts_on: null, ends_on: null, status: 'active', members: [] }} />
        </form>
      </Card>
    </section>
  )
}
