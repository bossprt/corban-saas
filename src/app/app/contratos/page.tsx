import Link from 'next/link'
import { ChevronRight, FilePlus2, Link2, Search, X } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { can } from '@/lib/access'
import { atLeast } from '@/lib/rbac'
import { requireAppContext } from '@/lib/appContext'
import { add, fromDecimalString, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { PAGE_SIZES, pageSize, termText } from '@/lib/commission/tableValues'
import { brlText } from '@/lib/receipts/format'
import { formatCpf } from '@/lib/cpf'
import { situationFilter, situationLabel, situationOptions, type Situation } from '@/lib/contractStatus'
import { activeCount, contractFilters } from '@/lib/contracts/listFilters'
import { isUuid } from '@/lib/team'
import { CpfSearchForm } from '@/components/CpfSearchForm'
import { MobileFilters } from '@/components/MobileFilters'
import { recalcContracts } from './actions'
import { bulkSeller } from './quick-actions'
import { QUICK_ACTIONS, QuickModal, type QuickAction } from './QuickModal'
import { RowMenu, type RowMenuItem } from './RowMenu'
import { AssociateModal } from './AssociateModal'
import { RecalcBar } from './RecalcBar'
import { formatDateSP } from '@/lib/dates'

type SP = Record<string, string | string[] | undefined>
const one = (v: string | string[] | undefined) => (typeof v === 'string' ? v : '')
const lbl = 'text-[13px] font-medium text-ink-soft'
const STATUS_TONE: Record<string, Tone> = { paid: 'received', approved: 'received', pending_external: 'diverged', rejected: 'reversed', cancelled: 'neutral' }
const ZERO = fromDecimalString('0')
const dec = (v: string | null | undefined) => (v ? fromDecimalString(v) : ZERO)
const money = (v: Rational | undefined) => brlText(toDecimalString(v ?? ZERO, 2))
const CLOSED_STATUSES = ['cancelled', 'rejected']

// One row of contract_list (migration 20261107001252): filtered, paged and summed in the database through the caller's
// RLS. Money comes as text (numeric::text) and is only parsed with the exact decimal helpers.
type Row = {
  id: string; external_proposal_id: string | null; status: string; requested_amount: string | null; released_amount: string | null; term: number | null
  full_name: string | null; cpf: string | null; customer_id: string | null; seller_id: string | null; created_at: string; paid_to_client_on: string | null
  formalization: string | null; physical_received_at: string | null; physical_bank_at: string | null
  case_id: string | null; current_stage_id: string | null; canonical_state: string | null; pendency_reason: string | null; situation: Situation | null
  bank_id: string | null; agreement_id: string | null; table_name: string | null; commission_group_id: string | null
  has_calc: boolean; received: string | null; company: string | null; originator: string | null
  has_po: boolean; rule_amount: string | null; payable: string | null; overridden: boolean; waiting: string | null; paid_on: string | null; grat_pending: boolean
  stale: boolean; repasse: string
}
type ListResult = { total: number; page: number; hidden_closed: number; any: boolean; sums: Record<'requested' | 'released' | 'received' | 'payable' | 'gain' | 'margin', string>; rows: Row[] }

// Contratos (part C1, ADR-0037): search every contract with the commission of each one. Finance sees what the company
// receives, what the seller gets and the margin; everyone else sees the contracts their scope allows (RLS), without
// the company values. A row opens the contract file.
const dateBrIso = (d: string) => (/^\d{4}-\d{2}-\d{2}$/.test(d) ? d.split('-').reverse().join('/') : '…')

export default async function ContractsPage({ searchParams }: { searchParams: Promise<SP> }) {
  const { supabase, access, membership } = await requireAppContext()
  const canCreate = can(access, 'propostas.create')
  const finance = can(access, 'financeiro.view')
  // Payout changes are the owner's alone: only the Administrador sees that a payout was changed (owner request 05/10/2026).
  const owner = atLeast(membership.role, 'admin')
  // Recalculating is for whoever can recalculate a contract on its page (owner request 06/10/2026: several at once).
  const canRecalc = can(access, 'propostas.edit') || can(access, 'financeiro.edit')
  const canMove = can(access, 'esteira.edit')
  const sp = await searchParams
  // A CPF typed in the search is looked up by POST (CpfSearchForm) and becomes cliente=<id>; a CPF that still reaches
  // the URL is ignored. Cancelled and rejected contracts are hidden unless asked for (owner, MEL-2026-0001, 09/10/2026).
  const f = contractFilters(k => one(sp[k]), situationFilter(one(sp.situacao)))
  const size = pageSize(one(sp.n), 25)
  const askedPage = Math.max(1, Number(one(sp.p)) || 1)

  // Filters, page and totals are worked out in the database: a click on a filter, a page or a row menu reads only the
  // rows shown and the sums, never every contract and commission line of the company (audit 06/11/2026, G3).
  const [{ data: listData, error: listError }, { data: banks }, { data: agreements }, { data: sellers }, { data: groups }, { data: stages }] = await Promise.all([
    supabase.rpc('contract_list', { p_org: membership.organization_id, p_filters: f, p_limit: size, p_page: askedPage }),
    supabase.from('organization_banks').select('id,name').order('name'),
    supabase.from('organization_agreements').select('id,name').order('name'),
    supabase.from('commercial_sellers').select('id,name,code,commission_group_id').order('name'),
    supabase.from('commission_groups').select('id,name').order('sort_order').order('name'),
    supabase.from('operational_stages').select('id,name,canonical_state,is_active').order('sort_order'),
  ])
  const list = (listData ?? { total: 0, page: 1, hidden_closed: 0, any: false, sums: {}, rows: [] }) as ListResult
  const rows = list.rows ?? []
  const total = list.total ?? 0
  const page = list.page ?? 1
  const pages = Math.max(1, Math.ceil(total / size))
  const stageName = new Map((stages ?? []).map(s => [s.id, s.name]))
  const situationText = (c: Row) => situationLabel(c.situation, { stageName: c.case_id && c.current_stage_id ? stageName.get(c.current_stage_id) : null })
  const bankName = new Map((banks ?? []).map(b => [b.id, b.name]))
  const agreementName = new Map((agreements ?? []).map(a => [a.id, a.name]))
  const sellerOf = new Map((sellers ?? []).map(s => [s.id, s]))
  const groupName = new Map((groups ?? []).map(g => [g.id, g.name]))
  // Seller = payable; margin = company margin by the rule + what the change kept in the company.
  const sellerGets = (c: Row) => (c.has_po ? dec(c.payable) : dec(c.originator))
  const marginOf = (c: Row) => (c.has_po ? add(dec(c.company), sub(dec(c.rule_amount), dec(c.payable))) : dec(c.company))
  const showClosed = !!f.encerradas || CLOSED_STATUSES.includes(f.situacao)
  const sumText = (k: keyof ListResult['sums']) => money(dec(list.sums?.[k]))

  // The quick-change window (?contrato=&acao=) over the list; forms return to the list with its filters.
  const quick = isUuid(one(sp.contrato)) && (QUICK_ACTIONS as readonly string[]).includes(one(sp.acao)) ? { id: one(sp.contrato), acao: one(sp.acao) as QuickAction } : null
  const qs = (patch: Record<string, string | number>) => {
    const q = new URLSearchParams(Object.entries({ ...f, n: size, p: page, ...patch }).filter(([, x]) => x !== '' && x !== undefined).map(([k, x]) => [k, String(x)]))
    return `/app/contratos?${q.toString()}`
  }

  const { data: chosenClient } = f.cliente ? await supabase.from('clients').select('id,full_name,cpf').eq('id', f.cliente).maybeSingle() : { data: null }
  const newHref = `/app/propostas/nova${f.cliente ? `?cliente=${f.cliente}` : ''}`
  const newButton = (label: string) => canCreate ? <Link href={newHref} className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><FilePlus2 size={16} aria-hidden />{label}</Link> : null

  // The arrow menu of each row: what this user may do, each item opening its window over this same list.
  const canEditContract = canRecalc
  const menuOf = (c: Row): RowMenuItem[] => {
    const at = (acao: string) => `${qs({})}&contrato=${c.id}&acao=${acao}`
    const items: RowMenuItem[] = []
    if (canMove && c.case_id) items.push({ acao: 'etapa', label: 'Mover etapa', href: at('etapa') })
    if (canEditContract) items.push({ acao: 'vendedor', label: 'Alterar vendedor', href: at('vendedor') })
    if (finance) items.push({ acao: 'comissao', label: c.has_calc ? (owner ? 'Alterar comissão' : 'Ver comissão') : 'Cadastrar comissão', href: at(c.has_calc ? 'comissao' : 'calcular') })
    if (canEditContract) items.push({ acao: 'dados', label: 'Dados do contrato', href: at('dados') }, { acao: 'ade', label: 'Alterar ADE', href: at('ade') })
    items.push({ acao: 'documentos', label: 'Documentos', href: at('documentos') }, { acao: 'observacoes', label: 'Observações', href: at('observacoes') },
      { acao: 'abrir', label: 'Abrir contrato completo', href: `/app/propostas/${c.id}` })
    return items
  }
  const payoutText = (c: Row) => !c.has_po ? '' : (c.paid_on ? `pago em ${new Date(`${c.paid_on}T12:00:00Z`).toLocaleDateString('pt-BR')}` : c.waiting === 'physical' ? 'aguardando físico' : c.waiting === 'client' ? 'aguardando pagamento ao cliente' : c.waiting === 'bank' ? 'aguardando comissão do banco' : c.waiting === 'divergent' ? 'comissão do banco divergente' : c.waiting === 'calculation' ? 'aguardando cálculo' : c.waiting === 'no_payout' ? (c.grat_pending ? 'aguardando Gratificação' : 'concluído · sem repasse') : 'liberado, a pagar')
    + (c.grat_pending && c.waiting !== 'no_payout' ? ' · aguardando Gratificação' : '')
  const badges = (c: Row) => <>
    <Badge tone={STATUS_TONE[c.situation ?? ''] ?? 'neutral'}>{situationText(c)}</Badge>
    {finance && (c.repasse === 'pago' ? <Badge tone="received">Pago ao vendedor</Badge> : c.repasse === 'creditado' ? <Badge tone="pending">A pagar ao vendedor</Badge> : c.repasse === 'aguardando' ? <Badge tone="neutral">Não pago ao vendedor</Badge> : c.repasse === 'sem_repasse' ? <Badge tone="neutral">Sem repasse</Badge> : null)}
    {c.formalization === 'physical' && <Badge tone={c.physical_received_at ? 'received' : 'pending'}>{c.physical_bank_at ? 'Físico no banco' : c.physical_received_at ? 'Físico recebido' : 'Físico pendente'}</Badge>}
    {c.pendency_reason && c.situation !== 'pending_external' && <span title={c.pendency_reason}><Badge tone="diverged">Pendência</Badge></span>}
  </>
  const emptyText = f.cliente ? 'Este cliente ainda não tem contrato.' : list.any ? 'Nenhum contrato com esses filtros.' : 'Nenhum contrato cadastrado ainda.'
  const filtersOn = activeCount({ ...f, cliente: '', pago_de: '', pago_ate: '', encerradas: '' }, ['q'])

  return (
    <section>
      {canRecalc && one(sp.acao) === 'associar' && <AssociateModal back={qs({})} />}
      {quick && <QuickModal id={quick.id} acao={quick.acao} back={qs({})} canEdit={canEditContract} finance={finance} owner={owner} canMove={canMove} />}
      <PageHeader title="Contratos" description="Busque os contratos e veja a comissão de cada um: o que a empresa recebe, o que o vendedor recebe pela tabela e o grupo dele, e a margem."
        actions={<>{canRecalc && <Link href={`${qs({})}&acao=associar`} scroll={false} className="inline-flex h-10 items-center gap-2 rounded-[10px] border border-line-strong bg-surface px-4 text-sm font-medium text-ink hover:bg-surface-muted"><Link2 size={16} aria-hidden />Associar proposta</Link>}{newButton('Novo contrato')}</>} />

      <Card className="mb-4">
        <CpfSearchForm action="/app/contratos" mode="filter" className="grid gap-3 p-4 sm:grid-cols-2 sm:p-5 lg:grid-cols-4">
          <label className={lbl}>Cliente (nome ou CPF) ou nº do contrato
            <input name="q" defaultValue={f.q} maxLength={80} placeholder="Nome, CPF ou nº do contrato" className="field mt-1.5" />
          </label>
          {f.cliente && <input type="hidden" name="cliente" value={f.cliente} />}
          {f.encerradas && <input type="hidden" name="encerradas" value="1" />}
          {f.pago_de && <input type="hidden" name="pago_de" value={f.pago_de} />}{f.pago_ate && <input type="hidden" name="pago_ate" value={f.pago_ate} />}
          <input type="hidden" name="n" value={size} />
          <MobileFilters active={filtersOn}>
            <label className={lbl}>Cadastrado de<input type="date" name="de" defaultValue={f.de} className="field mt-1.5" /></label>
            <label className={lbl}>Cadastrado até<input type="date" name="ate" defaultValue={f.ate} className="field mt-1.5" /></label>
            <label className={lbl}>Situação<select name="situacao" defaultValue={f.situacao} className="field mt-1.5"><option value="">Todas</option>{situationOptions((stages ?? []).filter(s => s.is_active)).map(o => <option key={o.value} value={o.value}>{o.label}</option>)}</select></label>
            <label className={lbl}>Banco<select name="banco" defaultValue={f.banco} className="field mt-1.5"><option value="">Todos</option><option value="none">Sem banco</option>{(banks ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
            <label className={lbl}>Convênio<select name="convenio" defaultValue={f.convenio} className="field mt-1.5"><option value="">Todos</option>{(agreements ?? []).map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            <label className={lbl}>Vendedor<select name="vendedor" defaultValue={f.vendedor} className="field mt-1.5"><option value="">Todos</option><option value="none">Sem vendedor</option>{(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}{s.name}</option>)}</select></label>
            <label className={lbl}>Grupo do vendedor<select name="grupo" defaultValue={f.grupo} className="field mt-1.5"><option value="">Todos</option>{(groups ?? []).map(g => <option key={g.id} value={g.id}>{g.name}</option>)}</select></label>
            {finance && <label className={lbl}>Comissão<select name="comissao" defaultValue={f.comissao} className="field mt-1.5"><option value="">Todas</option><option value="calculada">Calculada</option><option value="pendente">Não calculada</option></select></label>}
            {finance && <label className={lbl}>Repasse ao vendedor<select name="repasse" defaultValue={f.repasse} className="field mt-1.5"><option value="">Todos</option><option value="aguardando">Aguardando (cliente, físico ou banco)</option><option value="banco">Aguardando comissão do banco</option><option value="gratificacao">Aguardando Gratificação</option><option value="divergente">Comissão do banco divergente</option><option value="creditado">Liberado, a pagar</option><option value="pago">Pago ao vendedor</option><option value="sem_repasse">Sem repasse (vendedor recebe R$ 0)</option><option value="concluido">Concluído (pago ou sem repasse)</option></select></label>}
            {finance && <label className={`${lbl} flex items-center gap-2 self-end pb-2`}><input type="checkbox" name="desatualizado" value="1" defaultChecked={!!f.desatualizado} className="accent-[var(--brand)]" />Só comissão desatualizada</label>}
            {owner && <label className={`${lbl} flex items-center gap-2 self-end pb-2`}><input type="checkbox" name="alterado" value="1" defaultChecked={!!f.alterado} className="accent-[var(--brand)]" />Só repasse alterado</label>}
          </MobileFilters>
          <div className="flex items-end gap-2 lg:col-span-3">
            <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Search size={15} aria-hidden />Buscar</button>
            <Link href="/app/contratos" className="inline-flex h-10 items-center rounded-[10px] border border-line px-3 text-sm text-ink-soft hover:bg-surface-muted">Limpar</Link>
          </div>
        </CpfSearchForm>
        {(f.pago_de || f.pago_ate) && (
          <div className="flex flex-wrap items-center gap-3 border-t border-line px-5 py-3 text-sm">
            <span className="text-ink-soft">Pagos ao cliente {f.pago_de === f.pago_ate ? `em ${dateBrIso(f.pago_de)}` : `de ${dateBrIso(f.pago_de)} até ${dateBrIso(f.pago_ate)}`}</span>
            <Link href={qs({ pago_de: '', pago_ate: '', p: 1 })} className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-ink-soft hover:bg-surface-muted"><X size={14} aria-hidden />Tirar filtro da data</Link>
          </div>
        )}
        {f.cliente && (
          <div className="flex flex-wrap items-center gap-3 border-t border-line px-5 py-3 text-sm">
            <span className="text-ink-soft">Cliente: <Link href={`/app/clientes/${f.cliente}`} className="font-medium text-ink hover:text-brand">{chosenClient?.full_name ?? '—'}</Link> <span className="font-mono text-[13px] text-muted">{formatCpf(chosenClient?.cpf)}</span></span>
            <Link href={qs({ cliente: '', p: 1 })} className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-ink-soft hover:bg-surface-muted"><X size={14} aria-hidden />Tirar filtro do cliente</Link>
          </div>
        )}
      </Card>

      {listError && <p role="alert" className="mb-4 rounded-[10px] border border-[#FCA5A5] bg-[#FEF2F2] px-4 py-3 text-sm text-[#991B1B]">Não foi possível carregar os contratos agora. Tente de novo em instantes.</p>}

      <div className="mb-3 grid grid-cols-2 gap-3">
        {[['Total líquido', sumText('released')], ['Total bruto', sumText('requested')]].map(([k, v]) => (
          <Card key={k} className="px-4 py-3 sm:px-5 sm:py-4"><div className="text-xs text-muted">{k} · contratos filtrados</div><div className="num mt-1 text-lg font-semibold text-ink sm:text-xl">{v}</div></Card>
        ))}
      </div>

      {finance && <div className={`mb-4 grid grid-cols-2 gap-3 ${owner ? 'lg:grid-cols-4' : 'lg:grid-cols-3'}`}>
        {[['Empresa recebe', sumText('received')], ['Vendedores recebem', sumText('payable')], ['Margem', sumText('margin')], ...(owner ? [['Ganho com alterações de repasse', sumText('gain')]] : [])].map(([k, v]) => (
          <Card key={k} className="px-4 py-3 sm:px-5 sm:py-4"><div className="text-xs text-muted">{k} · contratos filtrados</div><div className="num mt-1 text-lg font-semibold text-ink sm:text-xl">{v}</div></Card>
        ))}
      </div>}

      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Contratos <Badge tone="neutral">{total}</Badge></span>}
          action={CLOSED_STATUSES.includes(f.situacao) ? undefined : <Link href={qs({ encerradas: f.encerradas ? '' : '1', p: 1 })} scroll={false} className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 text-sm text-ink-soft hover:bg-surface-muted">
            {f.encerradas ? 'Esconder canceladas e recusadas' : `Mostrar canceladas e recusadas (${showClosed ? 0 : list.hidden_closed ?? 0})`}</Link>} />
        {canRecalc && <div className="mt-3 hidden md:block"><RecalcBar action={recalcContracts} sellerAction={bulkSeller} sellers={(sellers ?? []).map(s => ({ id: s.id, name: `${s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}${s.name}` }))} /></div>}

        {/* Phone: one card per contract (client, situation, value), no sideways scrolling. */}
        <ul className="mt-3 grid gap-2 px-3 md:hidden" aria-label="Contratos">
          {rows.map(c => {
            const s = c.seller_id ? sellerOf.get(c.seller_id) : undefined
            return (
              <li key={c.id} className="relative rounded-[12px] border border-line bg-surface p-3.5">
                <div className="flex items-start gap-2">
                  <Link href={`/app/propostas/${c.id}`} className="min-w-0 flex-1">
                    <span className="block font-medium text-ink">{c.full_name ?? '—'}</span>
                    <span className="block truncate text-xs text-muted">{formatCpf(c.cpf)}{c.external_proposal_id ? ` · nº ${c.external_proposal_id}` : ''}</span>
                  </Link>
                  <RowMenu label={c.full_name ?? 'contrato'} items={menuOf(c)} />
                </div>
                <span className="mt-2 flex flex-wrap gap-1">{badges(c)}</span>
                <span className="mt-2 flex items-center justify-between gap-2 text-[13px]">
                  <span className="num font-semibold text-ink">{brlText(String(c.requested_amount ?? c.released_amount ?? '0'))}</span>
                  <span className="min-w-0 truncate text-xs text-ink-soft">{s?.name ?? ''}</span>
                </span>
                {finance && (c.has_calc
                  ? <span className="mt-1 block text-xs text-ink-soft">Empresa {money(dec(c.received))} · Vendedor {money(sellerGets(c))} · Margem {money(marginOf(c))}</span>
                  : <span className="mt-1 block"><Badge tone="pending">Comissão não calculada</Badge></span>)}
              </li>
            )
          })}
          {!rows.length && <li className="rounded-[12px] border border-line bg-surface px-4 py-8 text-center text-sm text-muted">{emptyText}{canCreate && <span className="mt-3 block">{newButton(f.cliente ? 'Cadastrar contrato para este cliente' : 'Cadastrar novo contrato')}</span>}</li>}
        </ul>

        <div className="mt-3 hidden overflow-x-auto md:block">
          <table className="w-full min-w-[940px] text-left text-[13px]">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr>
                <th className="w-10 pl-5 pr-1 py-2"><span className="sr-only">Marcar e alterar</span></th>
                <th className="px-5 py-2 font-medium">Cliente</th><th className="px-3 py-2 font-medium">Vendedor</th><th className="px-3 py-2 font-medium">Banco · tabela</th>
                <th className="px-3 py-2 text-right font-medium">Valor</th><th className="px-3 py-2 font-medium">Situação</th>
                {finance && <><th className="px-3 py-2 text-right font-medium">Empresa recebe</th><th className="px-3 py-2 text-right font-medium">Vendedor recebe</th><th className="px-3 py-2 text-right font-medium">Margem</th></>}
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody>
              {rows.map(c => {
                const s = c.seller_id ? sellerOf.get(c.seller_id) : undefined
                const margin = c.has_calc ? toDecimalString(marginOf(c), 2) : ''
                return (
                  <tr key={c.id} className="border-t border-line hover:bg-surface-muted/60">
                    <td className="pl-5 pr-1 py-2.5 align-top">
                      {canRecalc && <input type="checkbox" form="recalc-form" name="ids" value={c.id} data-stale={c.stale ? '1' : ''} aria-label={`Marcar ${c.full_name ?? 'contrato'}`} className="accent-[var(--brand)]" />}
                      <RowMenu label={c.full_name ?? 'contrato'} items={menuOf(c)} />
                    </td>
                    <td className="px-5 py-2.5">
                      <Link href={`/app/propostas/${c.id}`} className="group block">
                        <span className="block font-medium text-ink group-hover:text-brand">{c.full_name ?? '—'}</span>
                        <span className="text-xs text-muted">{formatCpf(c.cpf)}{c.external_proposal_id ? ` · nº ${c.external_proposal_id}` : ''} · {formatDateSP(c.created_at)}</span>
                      </Link>
                    </td>
                    <td className="px-3 py-2.5"><span className="block text-ink">{s?.name ?? '—'}</span><span className="text-xs text-muted">{c.commission_group_id ? groupName.get(c.commission_group_id) ?? '' : 'sem grupo'}</span>{c.stale && <Badge tone="pending" className="ml-1.5">Comissão desatualizada</Badge>}</td>
                    <td className="px-3 py-2.5"><span className="block text-ink">{bankName.get(c.bank_id ?? '') ?? '—'} · {agreementName.get(c.agreement_id ?? '') ?? '—'}</span><span className="text-xs text-muted">{c.table_name ?? '—'}{c.term ? ` · ${termText(c.term, c.term, c.term)}` : ''}</span></td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{brlText(String(c.requested_amount ?? c.released_amount ?? '0'))}{c.released_amount && c.released_amount !== c.requested_amount && <span className="block text-xs text-muted">líq. {brlText(String(c.released_amount))}</span>}</td>
                    <td className="px-3 py-2.5"><span className="flex max-w-[180px] flex-wrap gap-1">{badges(c)}</span></td>
                    {finance && (c.has_calc ? <>
                      <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(dec(c.received))}</td>
                      <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(sellerGets(c))}{owner && c.overridden && <Badge tone="pending" className="ml-1.5">Alterado</Badge>}
                        <span className="block text-[11px] text-muted">{payoutText(c)}</span></td>
                      <td className={`num whitespace-nowrap px-3 py-2.5 text-right font-medium ${margin.startsWith('-') ? 'text-[#B91C1C]' : 'text-ink'}`}>{brlText(margin)}</td>
                    </> : <td colSpan={3} className="px-3 py-2.5 text-right"><Badge tone="pending">Comissão não calculada</Badge></td>)}
                    <td className="px-3 py-2.5 text-right"><Link href={`/app/propostas/${c.id}`} aria-label={`Abrir contrato de ${c.full_name ?? 'cliente'}`} className="inline-flex size-8 items-center justify-center rounded-md text-muted hover:bg-surface-muted hover:text-ink"><ChevronRight size={16} aria-hidden /></Link></td>
                  </tr>
                )
              })}
              {!rows.length && <tr><td colSpan={10} className="px-5 py-8 text-center text-muted">
                <span className="block">{emptyText}</span>
                {canCreate && <span className="mt-3 inline-block">{newButton(f.cliente ? 'Cadastrar contrato para este cliente' : 'Cadastrar novo contrato')}</span>}
              </td></tr>}
            </tbody>
          </table>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm text-ink-soft">
          <span>{total ? `${(page - 1) * size + 1}–${Math.min(page * size, total)} de ${total}` : '0 contratos'}</span>
          <span className="flex items-center gap-1.5">Exibir {PAGE_SIZES.map(n => <Link key={n} href={qs({ n, p: 1 })} className={`rounded-md px-2 py-1 ${n === size ? 'bg-brand-soft font-semibold text-brand' : 'hover:bg-surface-muted'}`}>{n}</Link>)}
            <Link href={qs({ p: Math.max(1, page - 1) })} className={`ml-2 rounded-md border border-line px-2.5 py-1 ${page === 1 ? 'pointer-events-none opacity-40' : 'hover:bg-surface-muted'}`}>Anterior</Link>
            <span className="px-1">{page}/{pages}</span>
            <Link href={qs({ p: Math.min(pages, page + 1) })} className={`rounded-md border border-line px-2.5 py-1 ${page === pages ? 'pointer-events-none opacity-40' : 'hover:bg-surface-muted'}`}>Próxima</Link>
          </span>
        </div>
      </Card>
    </section>
  )
}
