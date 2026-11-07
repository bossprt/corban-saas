import Link from 'next/link'
import { FilePlus2, Calculator, FileSpreadsheet, RefreshCw, Search, X } from 'lucide-react'
import { Badge, ButtonLink, Card, PageHeader, type Tone } from '@/components/ui'
import { can, canImportBevicred, canImportContracts } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { listBevicredCredentials } from '@/lib/bevicred.server'
import { formatCpf } from '@/lib/cpf'
import { brlText } from '@/lib/receipts/format'
import { pipelineFilters } from '@/lib/contracts/listFilters'
import { CpfSearchForm } from '@/components/CpfSearchForm'
import { PipelineBoard, type BoardCard } from './PipelineBoard'
import { StageSelect } from './StageMove'
import { PreQueue } from './PreQueue'

// One case of pipeline_case_list (migration 20261107044229): read in the database, newest first, joined with the
// proposal and the seller. Amounts come as text.
type CaseRow = {
  id: string; proposal_id: string; current_stage_id: string; canonical_state: string; entered_stage_at: string; due_at: string | null; pendency_due_at: string | null; pendency_reason: string | null
  external_proposal_id: string | null; requested_amount: string | null; released_amount: string | null; full_name: string | null; cpf: string | null
  bank: string | null; table_name: string | null; seller_id: string | null; seller_name: string | null
}
type ListResult = { counts: Record<string, number>; open: number; total: number; alerts: number; rows: CaseRow[] }

// How many cases one screen shows at most. Above it the screen says "mostrando X de Y" (never a silent cut).
const LIMIT = 500
const CLOSED = ['paid', 'rejected', 'cancelled']
const STATE_TONE: Record<string, Tone> = {
  digitization_queue: 'neutral', digitizing: 'expected', submitted: 'paid-out', pending_external: 'diverged',
  approved: 'received', paid: 'received', rejected: 'reversed', cancelled: 'neutral',
}
const brl = (v: string | null) => (v === null || v === undefined ? '—' : brlText(v))
const amountOf = (c: CaseRow) => brl(c.released_amount ?? c.requested_amount)
// Server-rendered per request.
const requestTime = () => Date.now()
const days = (iso: string) => Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000))
type SP = { etapa?: string; visao?: string; estado?: string; atrasado?: string; q?: string; vendedor?: string; cliente?: string }

// Esteira: every proposal in the pipeline with its stage, how long it is there and the alerts that need action.
// Stages are the company's own (names and order); visibility follows the caller's scope (RLS).
export default async function PipelinePage({ searchParams }: { searchParams: Promise<SP> }) {
  const { supabase, access, organization } = await requireAppContext()
  const sp = await searchParams
  const filters = pipelineFilters(k => { const v = sp[k as keyof SP]; return typeof v === 'string' ? v : '' })

  const { data: stages } = await supabase.from('operational_stages').select('id,code,name,canonical_state,sort_order').eq('is_active', true).order('sort_order')
  const kanban = sp.visao === 'kanban'
  const stage = kanban ? undefined : (stages ?? []).find(s => s.code === sp.etapa)
  // Dashboard "Esteira agora" opens one canonical state (it groups every stage of that state).
  const state = kanban || stage ? undefined : sp.estado
  // Dashboard "parados além do prazo": open cases past the stage deadline (owner_dashboard overdue).
  const late = !kanban && !stage && sp.atrasado === '1'

  // Open cases (Kanban: plus the ones closed in the last 7 days, so a card just dropped in Paga stays in sight), or the
  // stage / state asked for. Newest first; the counters come from the database (audit 06/11/2026, G4/E6).
  const [{ data: listData, error: listError }, { count: portalPending }, { data: sellers }, { data: chosenClient }] = await Promise.all([
    supabase.rpc('pipeline_case_list', {
      p_org: organization.id, p_limit: LIMIT,
      p_filters: { ...filters, stage: stage?.id ?? '', state: state ?? '', late: late ? '1' : '', kanban: kanban ? '1' : '' },
    }),
    // Portal proposals (F7) wait outside the pipeline until validated.
    supabase.from('proposal_submissions').select('*', { count: 'exact', head: true }).eq('status', 'pending'),
    supabase.from('commercial_sellers').select('id,name,code').order('name'),
    filters.cliente ? supabase.from('clients').select('id,full_name').eq('id', filters.cliente).maybeSingle() : Promise.resolve({ data: null }),
  ])
  const list = (listData ?? { counts: {}, open: 0, total: 0, alerts: 0, rows: [] }) as ListResult
  const shown = list.rows ?? []
  const canMove = can(access, 'esteira.edit')
  const stageOptions = (stages ?? []).map(s => ({ id: s.id, name: s.name, canonical_state: s.canonical_state }))
  const stageName = new Map((stages ?? []).map(s => [s.id, s.name]))
  const count = (id: string) => list.counts?.[id] ?? 0
  const openCount = list.open ?? 0
  const capped = (list.total ?? 0) > shown.length

  const now = requestTime()
  const alertOf = (c: CaseRow) => {
    if (c.pendency_due_at && new Date(c.pendency_due_at).getTime() < now) return 'Pendência vencida'
    if (c.pendency_due_at && new Date(c.pendency_due_at).getTime() < now + 86_400_000) return 'Pendência vence em 24h'
    if (c.due_at && !CLOSED.includes(c.canonical_state) && new Date(c.due_at).getTime() < now) return 'Parada além do prazo'
    return ''
  }
  const alerts = list.alerts ?? 0
  // A company with a Bevicred credential gets the shortcut that opens the contract import already searching Bevicred.
  const canImport = canImportContracts(access)
  const bevicred = canImportBevicred(access) && (await listBevicredCredentials(organization.id).catch(() => [])).length > 0

  // Links keep the search and the seller filter (tabs, views).
  const href = (patch: Record<string, string>) => {
    const q = new URLSearchParams(Object.entries({ q: filters.q, vendedor: filters.vendedor, cliente: filters.cliente, ...patch }).filter(([, v]) => v))
    const s = q.toString()
    return `/app/propostas${s ? `?${s}` : ''}`
  }
  const filtering = !!(filters.q || filters.vendedor || filters.cliente)
  const keep = { etapa: stage ? stage.code : '', visao: kanban ? 'kanban' : '', estado: state ?? '', atrasado: late ? '1' : '' }
  const empty = filtering ? 'Nenhuma proposta com essa busca.' : 'Nenhuma proposta nesta etapa.'

  return (
    <section>
      <PageHeader
        title="Esteira"
        description={`${openCount} propostas em andamento${alerts ? ` · ${alerts} com alerta` : ''}`}
        actions={<>
          {can(access, 'esteira.edit') && (portalPending ?? 0) > 0 && <ButtonLink href="/app/propostas/validacao" variant="secondary">Aguardando validação <span className="num">{portalPending}</span></ButtonLink>}
          {can(access, 'propostas.create') && <ButtonLink href="/app/simulacoes" variant="secondary"><Calculator size={16} aria-hidden />Simular</ButtonLink>}
          {bevicred && <ButtonLink href="/app/propostas/importar?bevicred=1" variant="secondary"><RefreshCw size={16} aria-hidden />Buscar na Bevicred</ButtonLink>}
          {canImport && <ButtonLink href="/app/propostas/importar" variant="secondary"><FileSpreadsheet size={16} aria-hidden />Importar contratos</ButtonLink>}
          {can(access, 'propostas.create') && <ButtonLink href="/app/propostas/nova"><FilePlus2 size={16} aria-hidden />Nova proposta</ButtonLink>}
        </>}
      />

      <PreQueue />

      <CpfSearchForm action="/app/propostas" mode="filter" className="mb-4 flex flex-wrap items-end gap-2">
        {Object.entries(keep).filter(([, v]) => v).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
        {filters.cliente && <input type="hidden" name="cliente" value={filters.cliente} />}
        <label className="min-w-0 flex-1 basis-56 text-[13px] font-medium text-ink-soft">Buscar
          <input name="q" defaultValue={filters.q} maxLength={80} placeholder="Nome do cliente, CPF ou ADE" className="field mt-1.5" />
        </label>
        <label className="basis-44 text-[13px] font-medium text-ink-soft">Vendedor
          <select name="vendedor" defaultValue={filters.vendedor} className="field mt-1.5"><option value="">Todos</option><option value="none">Sem vendedor</option>
            {(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}{s.name}</option>)}</select>
        </label>
        <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Search size={15} aria-hidden />Buscar</button>
        {filtering && <Link href={href({ ...keep, q: '', vendedor: '', cliente: '' })} className="inline-flex h-10 items-center gap-1 rounded-[10px] border border-line px-3 text-sm text-ink-soft hover:bg-surface-muted"><X size={14} aria-hidden />Limpar</Link>}
      </CpfSearchForm>
      {filters.cliente && <p className="-mt-2 mb-4 text-sm text-ink-soft">Cliente: <Link href={`/app/clientes/${filters.cliente}`} className="font-medium text-ink hover:text-brand">{chosenClient?.full_name ?? '—'}</Link></p>}

      {late && <p className="mb-4 flex flex-wrap items-center gap-2 rounded-[10px] border border-line bg-surface-muted px-4 py-2 text-sm">
        <span className="text-ink-soft">Só os parados além do prazo da etapa</span>
        <Link href={href({})} className="text-brand hover:underline">Ver todos</Link></p>}
      <nav aria-label="Etapas" className="mb-4 flex gap-1 overflow-x-auto border-b border-line">
        <Link href={href({})} aria-current={!stage && !state && !late ? 'page' : undefined} className={`-mb-px whitespace-nowrap border-b-2 px-3 py-2.5 text-sm ${!stage && !state && !late ? 'border-brand font-semibold text-ink' : 'border-transparent text-ink-soft hover:text-ink'}`}>
          Em andamento <span className="num ml-1 text-xs text-muted">{openCount}</span>
        </Link>
        {(stages ?? []).map(s => (
          <Link key={s.id} href={href({ etapa: s.code })} aria-current={stage?.id === s.id || s.canonical_state === state ? 'page' : undefined}
            className={`-mb-px whitespace-nowrap border-b-2 px-3 py-2.5 text-sm ${stage?.id === s.id || s.canonical_state === state ? 'border-brand font-semibold text-ink' : 'border-transparent text-ink-soft hover:text-ink'}`}>
            {s.name} <span className="num ml-1 text-xs text-muted">{count(s.id)}</span>
          </Link>
        ))}
      </nav>

      <div className="mb-3 flex flex-wrap items-center justify-between gap-2 text-sm">
        <span className="text-ink-soft">{capped ? `Mostrando ${shown.length} de ${list.total} propostas, das mais novas para as mais antigas. Use a busca ou o filtro de vendedor para achar as outras.` : ''}</span>
        <span className="flex gap-1">
          <Link href={href({})} aria-current={!kanban ? 'page' : undefined} className={`rounded-lg px-3 py-1.5 ${!kanban ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted'}`}>Tabela</Link>
          <Link href={href({ visao: 'kanban' })} aria-current={kanban ? 'page' : undefined} className={`rounded-lg px-3 py-1.5 ${kanban ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted'}`}>Kanban</Link>
        </span>
      </div>

      {listError && <p role="alert" className="mb-4 rounded-[10px] border border-[#FCA5A5] bg-[#FEF2F2] px-4 py-3 text-sm text-[#991B1B]">Não foi possível carregar a esteira agora. Tente de novo em instantes.</p>}

      {kanban ? (
        <PipelineBoard
          canEdit={canMove}
          columns={(stages ?? []).map(st => ({ id: st.id, code: st.code, name: st.name, canonical_state: st.canonical_state, closed: CLOSED.includes(st.canonical_state) }))}
          cards={shown.map((c): BoardCard => ({
            caseId: c.id, proposalId: c.proposal_id, stageId: c.current_stage_id,
            name: c.full_name ?? 'Cliente',
            sub: [c.bank, c.external_proposal_id].filter(Boolean).join(' · ') || '—',
            amount: amountOf(c), days: days(c.entered_stage_at), alert: alertOf(c),
          }))}
        />
      ) : (
      <>
      {/* Phone: one card per proposal (client, stage, value), no sideways scrolling. */}
      <ul className="grid gap-2 md:hidden" aria-label="Propostas">
        {shown.map(c => {
          const d = days(c.entered_stage_at)
          const alert = alertOf(c)
          return (
            <li key={c.id}>
              <Link href={`/app/propostas/${c.proposal_id}`} className="block rounded-[12px] border border-line bg-surface p-3.5 active:bg-surface-muted">
                <span className="flex items-start justify-between gap-2">
                  <span className="min-w-0 font-medium text-ink">{c.full_name ?? 'Cliente'}</span>
                  <Badge tone={STATE_TONE[c.canonical_state] ?? 'neutral'} className="shrink-0">{stageName.get(c.current_stage_id) ?? c.canonical_state}</Badge>
                </span>
                <span className="mt-0.5 block truncate text-xs text-muted">{[c.bank, c.external_proposal_id && `ADE ${c.external_proposal_id}`].filter(Boolean).join(' · ') || '—'}</span>
                <span className="mt-2 flex items-center justify-between gap-2 text-[13px]">
                  <span className="num font-semibold text-ink">{amountOf(c)}</span>
                  <span className="min-w-0 truncate text-xs text-ink-soft">{c.seller_name ?? ''}</span>
                  <span className={`num shrink-0 text-xs ${d >= 4 && !CLOSED.includes(c.canonical_state) ? 'font-semibold text-diverged' : 'text-muted'}`}>{d === 0 ? 'hoje' : `${d} d`}</span>
                </span>
                {alert && <span className="mt-1.5 block text-xs font-medium text-diverged">{alert}</span>}
              </Link>
            </li>
          )
        })}
        {shown.length === 0 && <li className="rounded-[12px] border border-line bg-surface px-4 py-8 text-center text-sm text-muted">{empty}</li>}
      </ul>
      <Card className="hidden overflow-hidden md:block">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted">
              <tr>
                <th className="px-3 py-2.5">ADE</th><th className="px-3 py-2.5">Cliente</th><th className="px-3 py-2.5">CPF</th><th className="px-3 py-2.5">Banco / tabela</th>
                <th className="px-3 py-2.5 text-right">Valor</th><th className="px-3 py-2.5">Vendedor</th><th className="px-3 py-2.5">Etapa</th><th className="px-3 py-2.5 text-right">Na etapa</th><th className="px-3 py-2.5">Alerta</th>
              </tr>
            </thead>
            <tbody>
              {shown.map(c => {
                const d = days(c.entered_stage_at)
                const alert = alertOf(c)
                const name = c.full_name ?? 'Cliente'
                return (
                  <tr key={c.id} className="border-t border-line-strong/60 hover:bg-surface-muted">
                    <td className="px-3 py-2 font-mono"><Link href={`/app/propostas/${c.proposal_id}`} className="text-brand hover:text-brand-strong">{c.external_proposal_id ?? '—'}</Link></td>
                    <td className="px-3 py-2 font-medium text-ink"><Link href={`/app/propostas/${c.proposal_id}`} className="hover:text-brand">{name}</Link></td>
                    <td className="px-3 py-2 font-mono text-ink-soft">{formatCpf(c.cpf ?? '')}</td>
                    <td className="px-3 py-2 text-ink-soft">{[c.bank, c.table_name].filter(Boolean).join(' · ') || '—'}</td>
                    <td className="num px-3 py-2 text-right text-ink">{amountOf(c)}</td>
                    <td className="px-3 py-2 text-ink-soft">{c.seller_name ?? '—'}</td>
                    <td className="px-3 py-2">{canMove
                      ? <StageSelect compact caseId={c.id} proposalId={c.proposal_id} stages={stageOptions} currentStageId={c.current_stage_id} label={`Etapa de ${name}`} />
                      : <Badge tone={STATE_TONE[c.canonical_state] ?? 'neutral'}>{stageName.get(c.current_stage_id) ?? c.canonical_state}</Badge>}</td>
                    <td className={`num px-3 py-2 text-right ${d >= 4 && !CLOSED.includes(c.canonical_state) ? 'font-semibold text-diverged' : 'text-ink-soft'}`}>{d === 0 ? 'hoje' : `${d} d`}</td>
                    <td className="px-3 py-2 text-xs font-medium text-diverged" title={c.pendency_reason ?? undefined}>{alert}</td>
                  </tr>
                )
              })}
              {shown.length === 0 && <tr><td colSpan={9} className="px-4 py-10 text-center text-sm text-muted">{empty}</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
      </>
      )}
    </section>
  )
}
