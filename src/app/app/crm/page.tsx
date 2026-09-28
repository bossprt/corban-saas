import { redirect } from 'next/navigation'
import { Megaphone, Search, UserPlus } from 'lucide-react'
import { ButtonLink, Card, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { LEAD_STAGES, OPEN_STAGES, isLeadStage, type LeadStage } from '@/lib/crm'
import { isPortalUser } from '@/lib/portal'
import { digitsOnly, searchTerm } from '@/lib/search'
import { memberEmails } from '@/lib/team.server'
import { Board, type BoardCard, type BoardColumn } from './Board'
import { BoardSearch } from './BoardSearch'
import { createSalesLead, takeNextLead } from './actions'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const PER_COLUMN = 60
const label = 'text-[13px] font-medium text-ink-soft'
const CLOSED_WINDOW_MS = 30 * 24 * 3600 * 1000

// Won and lost leads stay on the board for 30 days; open ones always.
function closedSince() { return new Date(Date.now() - CLOSED_WINDOW_MS).toISOString() }
function nowMs() { return Date.now() }

type Sp = { campanha?: string; vendedor?: string; q?: string }

// Vendas: the team's board. Each seller sees their own leads (RLS); supervisors see their scope and filter by seller.
export default async function SalesBoardPage({ searchParams }: { searchParams: Promise<Sp> }) {
  const ctx = await requireAppContext()
  if (isPortalUser(ctx.access?.roleKey, ctx.modules)) redirect('/app/portal')
  if (!can(ctx.access, 'leads.view')) redirect('/app/hoje')
  const { supabase, organization, user, access } = ctx
  const sp = await searchParams
  const campaign = UUID.test(sp.campanha ?? '') ? sp.campanha! : null
  const supervisor = can(access, 'leads.approve')
  const seller = supervisor ? (sp.vendedor === 'eu' ? user.id : UUID.test(sp.vendedor ?? '') ? sp.vendedor! : null) : null
  const q = searchTerm(sp.q)

  let leadsQuery = supabase.from('leads')
    .select('id,full_name,status,next_contact_at,owner_user_id,campaign_id,customer_id,created_at')
    .or(`status.in.(${OPEN_STAGES.join(',')}),stage_changed_at.gte.${closedSince()}`)
    .order('created_at', { ascending: true })
    .limit(3000)
  if (campaign) leadsQuery = leadsQuery.eq('campaign_id', campaign)
  if (seller) leadsQuery = leadsQuery.eq('owner_user_id', seller)
  if (q) { const d = digitsOnly(q); leadsQuery = leadsQuery.or(d.length >= 4 ? `full_name.ilike.%${q}%,phone.ilike.%${d}%` : `full_name.ilike.%${q}%`) }

  const [{ data: leads }, { data: campaigns }, { data: queue }, { data: members }] = await Promise.all([
    leadsQuery,
    supabase.from('sales_campaigns').select('id,name,status').order('status').order('created_at', { ascending: false }),
    supabase.rpc('lead_queue_count', { p_org: organization.id, p_campaign: campaign }),
    supervisor ? supabase.from('organization_memberships').select('user_id').eq('status', 'active') : Promise.resolve({ data: [] as { user_id: string }[] }),
  ])
  const rows = leads ?? []
  const campaignName = new Map((campaigns ?? []).map(c => [c.id, c.name]))
  const emails = supervisor ? await memberEmails([...(members ?? []).map(m => m.user_id), ...rows.map(r => r.owner_user_id).filter(Boolean) as string[]]) : new Map<string, string>()
  const now = nowMs()

  const byStage = new Map<LeadStage, BoardCard[]>(LEAD_STAGES.map(s => [s, []]))
  for (const r of rows) {
    if (!isLeadStage(r.status)) continue
    byStage.get(r.status)!.push({
      id: r.id, name: r.full_name, status: r.status, campaign: r.campaign_id ? campaignName.get(r.campaign_id) ?? null : null,
      owner: r.owner_user_id ? (r.owner_user_id === user.id ? 'Você' : (emails.get(r.owner_user_id) ?? 'Vendedor').split('@')[0]) : null,
      nextContact: r.next_contact_at, overdue: !!r.next_contact_at && new Date(r.next_contact_at).getTime() < now, isClient: !!r.customer_id,
    })
  }
  // Open stages: the most urgent return first, then the oldest lead.
  const urgency = (c: BoardCard) => (c.nextContact ? new Date(c.nextContact).getTime() : Number.MAX_SAFE_INTEGER)
  const columns: BoardColumn[] = LEAD_STAGES.map(stage => {
    const cards = byStage.get(stage)!
    if ((OPEN_STAGES as readonly string[]).includes(stage)) cards.sort((a, b) => urgency(a) - urgency(b))
    else cards.reverse()
    return { stage, cards: cards.slice(0, PER_COLUMN), total: cards.length }
  })
  const openCount = rows.filter(r => (OPEN_STAGES as readonly string[]).includes(r.status)).length
  const overdue = rows.filter(r => r.next_contact_at && new Date(r.next_contact_at).getTime() < now && (OPEN_STAGES as readonly string[]).includes(r.status)).length
  const won = byStage.get('won')!.length
  const waiting = typeof queue === 'number' ? queue : 0
  const activeCampaigns = (campaigns ?? []).filter(c => c.status === 'active')

  return (
    <section>
      <PageHeader
        title="Vendas"
        description="Leads das campanhas e da integração, por etapa. Arraste o cartão para mudar a etapa; Proposta e Ganho seguem a proposta do cliente."
        actions={
          <>
            {supervisor && <ButtonLink href="/app/crm/campanhas" variant="secondary"><Megaphone size={16} aria-hidden />Campanhas</ButtonLink>}
            <form action={takeNextLead}>
              {campaign && <input type="hidden" name="campaign_id" value={campaign} />}
              <SubmitButton pendingText="Pegando..." className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">
                Pegar próximo lead <span className="num rounded-md bg-white/20 px-1.5 text-xs">{waiting}</span>
              </SubmitButton>
            </form>
          </>
        }
      />

      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
        {[['Em aberto', openCount], ['Retornos atrasados', overdue], ['Esperando na fila', waiting], ['Ganhos (30 dias)', won]].map(([k, v]) => (
          <Card key={String(k)} className="px-4 py-3">
            <span className="block text-xs text-muted">{k}</span>
            <span className={`num text-xl font-semibold ${k === 'Retornos atrasados' && Number(v) > 0 ? 'text-[#B91C1C]' : 'text-ink'}`}>{v}</span>
          </Card>
        ))}
      </div>

      <BoardSearch className="mb-4 flex flex-wrap items-end gap-3">
        <label className={`${label} min-w-[220px] flex-1`}>Buscar lead
          <input name="q" defaultValue={q ?? ''} placeholder="Nome, telefone ou CPF" className="field mt-1.5" />
        </label>
        <label className={label}>Campanha
          <select name="campanha" defaultValue={campaign ?? ''} className="field mt-1.5 min-w-[200px]">
            <option value="">Todas</option>
            {(campaigns ?? []).map(c => <option key={c.id} value={c.id}>{c.name}{c.status === 'closed' ? ' (encerrada)' : ''}</option>)}
          </select>
        </label>
        {supervisor && (
          <label className={label}>Vendedor
            <select name="vendedor" defaultValue={sp.vendedor ?? ''} className="field mt-1.5 min-w-[200px]">
              <option value="">Todos</option>
              <option value="eu">Só os meus</option>
              {(members ?? []).filter(m => m.user_id !== user.id).map(m => <option key={m.user_id} value={m.user_id}>{emails.get(m.user_id) ?? 'Usuário'}</option>)}
            </select>
          </label>
        )}
        <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Search size={15} aria-hidden />Filtrar</button>
      </BoardSearch>

      <Board columns={columns} showOwner={supervisor} />

      {can(access, 'leads.create') && (
        <details className="mt-6 rounded-[12px] border border-line bg-surface">
          <summary className="flex items-center gap-2 px-5 py-3.5 text-sm font-semibold text-ink"><UserPlus size={16} aria-hidden />Novo lead</summary>
          <form action={createSalesLead} className="grid gap-4 border-t border-line px-5 py-4 sm:grid-cols-2 lg:grid-cols-6">
            <label className={`${label} lg:col-span-2`}>Nome<input required name="full_name" minLength={2} maxLength={200} className="field mt-1.5" /></label>
            <label className={label}>Telefone<input name="phone" inputMode="tel" placeholder="(68) 99999-0000" className="field mt-1.5" /></label>
            <label className={label}>CPF<input name="cpf" inputMode="numeric" placeholder="000.000.000-00" className="field mt-1.5" /></label>
            <label className={`${label} lg:col-span-2`}>Campanha
              <select name="campaign_id" defaultValue={campaign ?? ''} className="field mt-1.5">
                <option value="">Sem campanha</option>
                {activeCampaigns.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </label>
            <label className={`${label} lg:col-span-2`}>E-mail<input name="email" type="email" className="field mt-1.5" /></label>
            <div className="flex items-end lg:col-span-4">
              <SubmitButton pendingText="Salvando..." className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Cadastrar lead</SubmitButton>
              <span className="ml-3 text-xs text-muted">Informe o CPF ou um telefone. Se o CPF já for cliente, o lead fica ligado à ficha dele.</span>
            </div>
          </form>
        </details>
      )}
    </section>
  )
}
