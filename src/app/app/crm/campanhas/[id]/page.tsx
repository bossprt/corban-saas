import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { ArrowLeft, KanbanSquare, Upload } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isDistribution, STAGE_LABEL, LEAD_STAGES } from '@/lib/crm'
import { leadOwners } from '@/lib/crm.server'
import { assignLeads, closeCampaign, deleteCampaign, saveCampaign } from '../../actions'
import { CampaignFields } from '../CampaignFields'
import { TemplateDownload } from '../TemplateDownload'
import { CampaignImport } from './CampaignImport'

const label = 'text-[13px] font-medium text-ink-soft'
const pct = (a: number, b: number) => (b > 0 ? `${Math.round((a / b) * 100)}%` : '—')
const dateTime = (iso: string) => new Date(iso).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Sao_Paulo' })

export default async function CampaignPage({ params }: { params: Promise<{ id: string }> }) {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'leads.approve')) redirect('/app/crm')
  const { id } = await params
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound()
  const [{ data: c }, { data: members }, { data: imports }, { data: counts }, people] = await Promise.all([
    supabase.from('sales_campaigns').select('id,name,description,distribution,starts_on,ends_on,status').eq('id', id).maybeSingle(),
    supabase.from('sales_campaign_members').select('user_id').eq('campaign_id', id),
    supabase.from('sales_campaign_imports').select('id,file_name,file_sha256,row_count,created_count,linked_client_count,duplicate_count,invalid_count,created_at').eq('campaign_id', id).order('created_at', { ascending: false }).limit(20),
    supabase.rpc('sales_lead_counts', { p_org: organization.id }),
    leadOwners(supabase),
  ])
  if (!c || !isDistribution(c.distribution)) notFound()
  const name = new Map(people.map(p => [p.id, p.name]))
  const rows = ((counts ?? []) as { campaign_id: string | null; owner_user_id: string | null; status: string; total: number }[]).filter(r => r.campaign_id === id)
  const total = rows.reduce((s, r) => s + Number(r.total), 0)
  const byStage = new Map(LEAD_STAGES.map(s => [s, rows.filter(r => r.status === s).reduce((a, r) => a + Number(r.total), 0)]))
  const waiting = rows.filter(r => !r.owner_user_id && ['new', 'contacted', 'negotiating'].includes(r.status)).reduce((a, r) => a + Number(r.total), 0)
  const sellers = new Map<string, { total: number; open: number; won: number; lost: number }>()
  for (const r of rows) {
    if (!r.owner_user_id) continue
    const s = sellers.get(r.owner_user_id) ?? { total: 0, open: 0, won: 0, lost: 0 }
    const n = Number(r.total)
    s.total += n
    if (['new', 'contacted', 'negotiating', 'proposal'].includes(r.status)) s.open += n
    if (r.status === 'won') s.won += n
    if (r.status === 'lost') s.lost += n
    sellers.set(r.owner_user_id, s)
  }
  const back = `/app/crm/campanhas/${id}`

  return (
    <section>
      <Link href="/app/crm/campanhas" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Campanhas</Link>
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-3">{c.name}{c.status === 'closed' && <Badge tone="neutral">Encerrada</Badge>}</span>}
        description={c.description ?? undefined}
        actions={<>
          <ButtonLink href={`/app/crm?campanha=${id}`} variant="secondary"><KanbanSquare size={16} aria-hidden />Ver no quadro</ButtonLink>
          {c.status === 'active' && <ButtonLink href="#planilha"><Upload size={16} aria-hidden />Subir planilha</ButtonLink>}
        </>}
      />

      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4 lg:grid-cols-7">
        {[['Leads', total], ['Sem vendedor', waiting], ...LEAD_STAGES.filter(s => s !== 'new').map(s => [STAGE_LABEL[s], byStage.get(s) ?? 0])].map(([k, v]) => (
          <Card key={String(k)} className="px-4 py-3"><span className="block text-xs text-muted">{k}</span><span className="num text-xl font-semibold text-ink">{v}</span></Card>
        ))}
      </div>

      <div className="grid gap-4 lg:grid-cols-[1.3fr_1fr]">
        <div className="grid content-start gap-4">
          <Card id="planilha" className="scroll-mt-6 p-5">
            <div className="mb-1 flex flex-wrap items-center justify-between gap-2">
              <h2 className="text-base font-semibold text-ink">Subir planilha</h2>
              <TemplateDownload />
            </div>
            <p className="mb-4 text-sm text-muted">Quem já é cliente fica ligado à ficha pelo CPF ou telefone, sem duplicar. Quem é novo entra como lead e vira cliente quando o vendedor simular.</p>
            {c.status === 'active'
              ? <CampaignImport campaignId={id} alreadyImported={(imports ?? []).map(i => i.file_sha256)} />
              : <p className="text-sm text-muted">Campanha encerrada: reabra para importar.</p>}
          </Card>

          <Card className="overflow-hidden">
            <CardHeader title="Resultado por vendedor" />
            <div className="mt-3 overflow-x-auto">
              <table className="w-full min-w-[520px] text-left text-sm">
                <thead className="border-y border-line bg-surface-muted text-xs text-muted"><tr><th className="px-5 py-2 font-medium">Vendedor</th><th className="px-3 py-2 text-right font-medium">Leads</th><th className="px-3 py-2 text-right font-medium">Em aberto</th><th className="px-3 py-2 text-right font-medium">Ganhos</th><th className="px-3 py-2 text-right font-medium">Perdidos</th><th className="px-5 py-2 text-right font-medium">Conversão</th></tr></thead>
                <tbody>
                  {[...sellers].map(([u, s]) => (
                    <tr key={u} className="border-t border-line">
                      <td className="px-5 py-2.5"><Link href={`/app/crm?campanha=${id}&vendedor=${u}`} className="text-ink hover:text-brand">{name.get(u) ?? 'Usuário'}</Link></td>
                      <td className="num px-3 py-2.5 text-right">{s.total}</td><td className="num px-3 py-2.5 text-right">{s.open}</td>
                      <td className="num px-3 py-2.5 text-right font-medium text-ink">{s.won}</td><td className="num px-3 py-2.5 text-right">{s.lost}</td>
                      <td className="num px-5 py-2.5 text-right">{pct(s.won, s.total)}</td>
                    </tr>
                  ))}
                  {sellers.size === 0 && <tr><td colSpan={6} className="px-5 py-8 text-center text-muted">Nenhum lead com vendedor ainda.</td></tr>}
                </tbody>
              </table>
            </div>
          </Card>

          <Card className="overflow-hidden">
            <CardHeader title="Planilhas importadas" />
            <ul className="px-5 py-2">
              {(imports ?? []).map(i => (
                <li key={i.id} className="border-t border-line py-2.5 text-sm first:border-t-0">
                  <span className="flex flex-wrap justify-between gap-2"><span className="font-medium text-ink">{i.file_name}</span><span className="text-xs text-muted">{dateTime(i.created_at)}</span></span>
                  <span className="block text-xs text-muted">{i.row_count} linha(s): {i.created_count} novo(s) ({i.linked_client_count} já cliente), {i.duplicate_count} repetido(s), {i.invalid_count} sem dados</span>
                </li>
              ))}
              {!imports?.length && <li className="py-4 text-sm text-muted">Nenhuma planilha ainda.</li>}
            </ul>
          </Card>
        </div>

        <div className="grid content-start gap-4">
          {c.status === 'active' && waiting > 0 && (
            <Card>
              <CardHeader title="Distribuir leads" />
              <form action={assignLeads} className="grid gap-3 px-5 pb-5 pt-3">
                <input type="hidden" name="campaign_id" value={id} />
                <input type="hidden" name="back" value={back} />
                <label className={label}>Quantos<input name="count" type="number" min={1} max={Math.min(1000, waiting)} defaultValue={Math.min(50, waiting)} required className="field mt-1.5" /></label>
                <label className={label}>Para
                  <select name="owner_user_id" required defaultValue="" className="field mt-1.5">
                    <option value="" disabled>Escolha o vendedor</option>
                    {people.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                  </select>
                </label>
                <SubmitButton pendingText="Distribuindo..." className="inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Distribuir</SubmitButton>
                <span className="text-xs text-muted">{waiting} lead(s) sem vendedor. Vão os mais antigos primeiro.</span>
              </form>
            </Card>
          )}
        </div>
      </div>

      <Card className="mt-4 p-5">
        <h2 className="mb-3 text-base font-semibold text-ink">Configuração</h2>
        <form action={saveCampaign}>
          <CampaignFields lockedAtStart people={people}
            values={{ id: c.id, name: c.name, description: c.description, distribution: c.distribution, starts_on: c.starts_on, ends_on: c.ends_on, status: c.status === 'closed' ? 'closed' : 'active', members: (members ?? []).map(m => m.user_id) }} />
        </form>
      </Card>

      <Card className="mt-4 p-5">
        <h2 className="text-base font-semibold text-ink">Encerrar ou excluir</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <form action={closeCampaign} className="grid content-start gap-2 rounded-[12px] border border-line p-4">
            <input type="hidden" name="campaign_id" value={c.id} />
            <p className="text-sm font-medium text-ink">Encerrar campanha</p>
            <p className="text-xs text-muted">Para campanha que acabou. Os leads em aberto (novo, contatado, negociando) vão para Perdido com o motivo &quot;Campanha encerrada&quot; e saem do quadro. Leads em proposta ou vendidos continuam. O histórico fica.</p>
            <div><SubmitButton pendingText="Encerrando..." className="h-9 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted">Encerrar campanha</SubmitButton></div>
          </form>
          <form action={deleteCampaign} className="grid content-start gap-2 rounded-[12px] border border-[#F3C4C4] p-4">
            <input type="hidden" name="campaign_id" value={c.id} />
            <p className="text-sm font-medium text-[#991B1B]">Excluir campanha</p>
            <p className="text-xs text-muted">Para campanha de teste ou planilha errada. Apaga a campanha, os {total} lead(s) e o histórico deles. Os clientes do cadastro não são apagados. Não funciona se algum lead virou proposta ou venda.</p>
            <label className={label}>Digite o nome da campanha para confirmar<input name="confirm_name" required autoComplete="off" placeholder={c.name} className="field mt-1.5" /></label>
            <div><SubmitButton pendingText="Excluindo..." className="h-9 rounded-[10px] bg-[#B91C1C] px-3 text-sm font-semibold text-white hover:bg-[#991B1B]">Excluir campanha</SubmitButton></div>
          </form>
        </div>
      </Card>
    </section>
  )
}
