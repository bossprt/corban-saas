import Link from 'next/link'
import { ChevronRight, FilePlus2, Search, X } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { can } from '@/lib/access'
import { atLeast } from '@/lib/rbac'
import { requireAppContext } from '@/lib/appContext'
import { fetchAll } from '@/lib/fetchAll'
import { add, fromDecimalString, mul, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { PAGE_SIZES, pageSize, termText } from '@/lib/commission/tableValues'
import { brlText } from '@/lib/receipts/format'
import { formatCpf } from '@/lib/cpf'
import { isUuid } from '@/lib/team'
import { CpfSearchForm } from '@/components/CpfSearchForm'
import { recalcContracts } from './actions'
import { RecalcBar } from './RecalcBar'

type SP = Record<string, string | string[] | undefined>
const one = (v: string | string[] | undefined) => (typeof v === 'string' ? v : '')
const lbl = 'text-[13px] font-medium text-ink-soft'
const STATUS_LABEL: Record<string, string> = {
  digitization_queue: 'Aguardando digitação', digitizing: 'Em digitação', submitted: 'Em análise', pending_external: 'Pendência',
  approved: 'Aprovado', paid: 'Pago ao cliente', rejected: 'Recusado', cancelled: 'Cancelado',
}
const STATUS_TONE: Record<string, Tone> = { paid: 'received', approved: 'received', pending_external: 'diverged', rejected: 'reversed', cancelled: 'neutral' }
const CPF_LIKE = /^\s*\d{3}\.?\d{3}\.?\d{3}-?\d{2}\s*$/
const ZERO = fromDecimalString('0')
const money = (v: Rational | undefined) => brlText(toDecimalString(v ?? ZERO, 2))

type Contract = { id: string; external_proposal_id: string | null; status: string; requested_amount: string | null; released_amount: string | null; term: number | null; customer_snapshot: { full_name?: string; cpf?: string } | null; customer_id: string | null; seller_id: string | null; product_table_version_id: string | null; created_at: string; paid_to_client_on: string | null }
// The embedded calculation comes back as one object (many-to-one); typed loosely by the untyped client.
type CalcLine = { line_kind: string; amount: string; multiplier: number; proposal_commission_calcs: { proposal_id: string } | { proposal_id: string }[] }

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
  const sp = await searchParams
  const text = one(sp.q).trim()
  const f = {
    de: one(sp.de), ate: one(sp.ate), banco: one(sp.banco), convenio: one(sp.convenio), vendedor: one(sp.vendedor), grupo: one(sp.grupo),
    situacao: one(sp.situacao), cliente: isUuid(one(sp.cliente)) ? one(sp.cliente) : '', comissao: one(sp.comissao), alterado: one(sp.alterado), repasse: one(sp.repasse), desatualizado: one(sp.desatualizado),
    // Paid to the client between these dates (the dashboard opens the contracts behind each number).
    pago_de: one(sp.pago_de), pago_ate: one(sp.pago_ate),
    // A CPF typed in the search is looked up by POST (CpfSearchForm) and becomes cliente=<id>; a CPF that still reaches
    // the URL is ignored.
    q: CPF_LIKE.test(text) ? '' : text.toLowerCase(),
  }

  const [contracts, { data: versions }, { data: tables }, { data: routes }, { data: banks }, { data: agreements }, { data: sellers }, { data: groups }] = await Promise.all([
    fetchAll<Contract>((a, b) => supabase.from('proposals_v2').select('id,external_proposal_id,status,requested_amount,released_amount,term,customer_snapshot,customer_id,seller_id,product_table_version_id,created_at,paid_to_client_on')
      .order('created_at', { ascending: false }).order('id').range(a, b)),
    supabase.from('product_table_versions').select('id,product_table_id,version'),
    supabase.from('product_tables').select('id,name,route_id'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_agreement_id'),
    supabase.from('organization_banks').select('id,name').order('name'),
    supabase.from('organization_agreements').select('id,name').order('name'),
    supabase.from('commercial_sellers').select('id,name,code,commission_group_id').order('name'),
    supabase.from('commission_groups').select('id,name').order('sort_order').order('name'),
  ])
  const lines = finance ? await fetchAll<CalcLine>((a, b) => supabase.from('proposal_commission_lines')
    .select('line_kind,amount,multiplier,proposal_commission_calcs!inner(proposal_id,status)').eq('proposal_commission_calcs.status', 'active')
    .order('id').range(a, b)) : []
  // What is payable to the seller (the owner's or a manager's change, part C2) per contract.
  const { data: payoutRows } = finance ? await supabase.rpc('contract_payout_totals', { p_org: membership.organization_id }) : { data: [] }
  // Seller and group each calculation used: when the contract's seller or that seller's group changed since, the
  // commission is out of date and the row says so (recalculate to apply the current group).
  const { data: calcRows } = finance ? await supabase.from('proposal_commission_calcs').select('proposal_id,seller_id,group_id').eq('status', 'active') : { data: [] }
  const calcOf = new Map(((calcRows ?? []) as { proposal_id: string; seller_id: string | null; group_id: string | null }[]).map(r => [r.proposal_id, r]))
  const payout = new Map(((payoutRows ?? []) as { proposal_id: string; rule_amount: string; payable: string; overridden: boolean; waiting: string | null; credited: string; paid_on: string | null }[]).map(r => [r.proposal_id, r]))
  const repasseOf = (id: string) => { const po = payout.get(id); return !po ? '' : po.paid_on ? 'pago' : po.waiting === 'no_payout' ? 'sem_repasse' : po.waiting ? 'aguardando' : 'creditado' }
  const waitingOf = (id: string) => payout.get(id)?.waiting ?? ''
  const totals = new Map<string, Map<string, Rational>>()
  for (const l of lines) {
    const calc = Array.isArray(l.proposal_commission_calcs) ? l.proposal_commission_calcs[0] : l.proposal_commission_calcs
    const pid = calc?.proposal_id
    if (!pid) continue
    const m = totals.get(pid) ?? new Map<string, Rational>()
    m.set(l.line_kind, add(m.get(l.line_kind) ?? ZERO, mul(fromDecimalString(String(l.amount)), fromDecimalString(String(l.multiplier)))))
    totals.set(pid, m)
  }

  // Seller = payable; margin = company margin by the rule + what the change kept in the company.
  for (const [pid, m] of totals) {
    const po = payout.get(pid)
    if (!po) continue
    const gain = sub(fromDecimalString(String(po.rule_amount)), fromDecimalString(String(po.payable)))
    m.set('payable', fromDecimalString(String(po.payable)))
    m.set('gain', gain)
    m.set('margin', add(m.get('company') ?? ZERO, gain))
  }
  const versionOf = new Map((versions ?? []).map(v => [v.id, v]))
  const tableOf = new Map((tables ?? []).map(t => [t.id, t]))
  const routeOf = new Map((routes ?? []).map(r => [r.id, r]))
  const bankName = new Map((banks ?? []).map(b => [b.id, b.name]))
  const agreementName = new Map((agreements ?? []).map(a => [a.id, a.name]))
  const sellerOf = new Map((sellers ?? []).map(s => [s.id, s]))
  const groupName = new Map((groups ?? []).map(g => [g.id, g.name]))
  const stale = (c: Contract) => {
    const k = calcOf.get(c.id)
    return !!k && (k.seller_id !== c.seller_id || k.group_id !== (c.seller_id ? sellerOf.get(c.seller_id)?.commission_group_id ?? null : null))
  }
  const where = (c: Contract) => {
    const v = c.product_table_version_id ? versionOf.get(c.product_table_version_id) : undefined
    const t = v ? tableOf.get(v.product_table_id) : undefined
    const r = t ? routeOf.get(t.route_id) : undefined
    return { table: t?.name ?? '—', bank: r?.org_bank_id ?? '', agreement: r?.org_agreement_id ?? '' }
  }

  const filtered = contracts.map(c => ({ c, w: where(c), s: c.seller_id ? sellerOf.get(c.seller_id) : undefined })).filter(({ c, w, s }) =>
    (!f.de || c.created_at.slice(0, 10) >= f.de) && (!f.ate || c.created_at.slice(0, 10) <= f.ate)
    && (!f.banco || w.bank === f.banco) && (!f.convenio || w.agreement === f.convenio)
    && (!f.vendedor || c.seller_id === f.vendedor) && (!f.grupo || s?.commission_group_id === f.grupo)
    && (!f.situacao || c.status === f.situacao) && (!f.cliente || c.customer_id === f.cliente)
    && (!f.comissao || (f.comissao === 'calculada') === totals.has(c.id))
    && (!f.alterado || !!payout.get(c.id)?.overridden)
    && (!f.desatualizado || stale(c))
    && (!f.pago_de || (!!c.paid_to_client_on && c.paid_to_client_on >= f.pago_de)) && (!f.pago_ate || (!!c.paid_to_client_on && c.paid_to_client_on <= f.pago_ate))
    && (!f.repasse || repasseOf(c.id) === f.repasse || (f.repasse === 'concluido' && ['pago', 'sem_repasse'].includes(repasseOf(c.id)))
      || (f.repasse === 'banco' && waitingOf(c.id) === 'bank') || (f.repasse === 'divergente' && waitingOf(c.id) === 'divergent'))
    && (!f.q || String(c.customer_snapshot?.full_name ?? '').toLowerCase().includes(f.q) || String(c.external_proposal_id ?? '').toLowerCase().includes(f.q)))
  const size = pageSize(one(sp.n), 25), pages = Math.max(1, Math.ceil(filtered.length / size))
  const page = Math.min(Math.max(1, Number(one(sp.p)) || 1), pages)
  const rows = filtered.slice((page - 1) * size, page * size)
  const sum = (kind: string) => filtered.reduce((acc, x) => add(acc, totals.get(x.c.id)?.get(kind) ?? ZERO), ZERO)
  const qs = (patch: Record<string, string | number>) => {
    const q = new URLSearchParams(Object.entries({ ...f, q: f.q ? text : '', n: size, p: page, ...patch }).filter(([, x]) => x !== '' && x !== undefined).map(([k, x]) => [k, String(x)]))
    return `/app/contratos?${q.toString()}`
  }

  const { data: chosenClient } = f.cliente ? await supabase.from('clients').select('id,full_name,cpf').eq('id', f.cliente).maybeSingle() : { data: null }
  const newHref = `/app/propostas/nova${f.cliente ? `?cliente=${f.cliente}` : ''}`
  const newButton = (label: string) => canCreate ? <Link href={newHref} className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><FilePlus2 size={16} aria-hidden />{label}</Link> : null

  return (
    <section>
      <PageHeader title="Contratos" description="Busque os contratos e veja a comissão de cada um: o que a empresa recebe, o que o vendedor recebe pela tabela e o grupo dele, e a margem." actions={newButton('Novo contrato')} />

      <Card className="mb-4">
        <CpfSearchForm action="/app/contratos" mode="filter" className="grid gap-3 p-5 sm:grid-cols-2 lg:grid-cols-4">
          <label className={lbl}>Cliente (nome ou CPF) ou nº do contrato
            <input name="q" defaultValue={f.q ? text : ''} maxLength={80} placeholder="Nome, CPF ou nº do contrato" className="field mt-1.5" />
          </label>
          {f.cliente && <input type="hidden" name="cliente" value={f.cliente} />}
          {f.pago_de && <input type="hidden" name="pago_de" value={f.pago_de} />}{f.pago_ate && <input type="hidden" name="pago_ate" value={f.pago_ate} />}
          <label className={lbl}>De<input type="date" name="de" defaultValue={f.de} className="field mt-1.5" /></label>
          <label className={lbl}>Até<input type="date" name="ate" defaultValue={f.ate} className="field mt-1.5" /></label>
          <label className={lbl}>Situação<select name="situacao" defaultValue={f.situacao} className="field mt-1.5"><option value="">Todas</option>{Object.entries(STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
          <label className={lbl}>Banco<select name="banco" defaultValue={f.banco} className="field mt-1.5"><option value="">Todos</option>{(banks ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          <label className={lbl}>Convênio<select name="convenio" defaultValue={f.convenio} className="field mt-1.5"><option value="">Todos</option>{(agreements ?? []).map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          <label className={lbl}>Vendedor<select name="vendedor" defaultValue={f.vendedor} className="field mt-1.5"><option value="">Todos</option>{(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}{s.name}</option>)}</select></label>
          <label className={lbl}>Grupo do vendedor<select name="grupo" defaultValue={f.grupo} className="field mt-1.5"><option value="">Todos</option>{(groups ?? []).map(g => <option key={g.id} value={g.id}>{g.name}</option>)}</select></label>
          {finance && <label className={lbl}>Comissão<select name="comissao" defaultValue={f.comissao} className="field mt-1.5"><option value="">Todas</option><option value="calculada">Calculada</option><option value="pendente">Não calculada</option></select></label>}
          {finance && <label className={lbl}>Repasse ao vendedor<select name="repasse" defaultValue={f.repasse} className="field mt-1.5"><option value="">Todos</option><option value="aguardando">Aguardando (cliente, físico ou banco)</option><option value="banco">Aguardando comissão do banco</option><option value="divergente">Comissão do banco divergente</option><option value="creditado">Liberado, a pagar</option><option value="pago">Pago ao vendedor</option><option value="sem_repasse">Sem repasse (vendedor recebe R$ 0)</option><option value="concluido">Concluído (pago ou sem repasse)</option></select></label>}
          {finance && <label className={`${lbl} flex items-center gap-2 self-end pb-2`}><input type="checkbox" name="desatualizado" value="1" defaultChecked={!!f.desatualizado} className="accent-[var(--brand)]" />Só comissão desatualizada</label>}
          {owner && <label className={`${lbl} flex items-center gap-2 self-end pb-2`}><input type="checkbox" name="alterado" value="1" defaultChecked={!!f.alterado} className="accent-[var(--brand)]" />Só repasse alterado</label>}
          <input type="hidden" name="n" value={size} />
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

      {finance && <div className={`mb-4 grid gap-3 sm:grid-cols-2 ${owner ? 'lg:grid-cols-4' : 'lg:grid-cols-3'}`}>
        {[['Empresa recebe', sum('received')], ['Vendedores recebem', sum('payable')], ['Margem', sum('margin')], ...(owner ? [['Ganho com alterações de repasse', sum('gain')]] : [])].map(([k, v]) => (
          <Card key={String(k)} className="px-5 py-4"><div className="text-xs text-muted">{String(k)} · contratos filtrados</div><div className="num mt-1 text-xl font-semibold text-ink">{money(v as Rational)}</div></Card>
        ))}
      </div>}

      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Contratos <Badge tone="neutral">{filtered.length}</Badge></span>} />
        {canRecalc && <div className="mt-3"><RecalcBar action={recalcContracts} /></div>}
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[940px] text-left text-[13px]">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr>
                {canRecalc && <th className="w-10 pl-5 pr-1 py-2"><span className="sr-only">Marcar</span></th>}
                <th className="px-5 py-2 font-medium">Cliente</th><th className="px-3 py-2 font-medium">Vendedor</th><th className="px-3 py-2 font-medium">Banco · tabela</th>
                <th className="px-3 py-2 text-right font-medium">Valor</th><th className="px-3 py-2 font-medium">Situação</th>
                {finance && <><th className="px-3 py-2 text-right font-medium">Empresa recebe</th><th className="px-3 py-2 text-right font-medium">Vendedor recebe</th><th className="px-3 py-2 text-right font-medium">Margem</th></>}
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody>
              {rows.map(({ c, w, s }) => {
                const t = totals.get(c.id)
                const margin = t ? toDecimalString(t.get('margin') ?? t.get('company') ?? ZERO, 2) : ''
                return (
                  <tr key={c.id} className="border-t border-line hover:bg-surface-muted/60">
                    {canRecalc && <td className="pl-5 pr-1 py-2.5"><input type="checkbox" form="recalc-form" name="ids" value={c.id} data-stale={stale(c) ? '1' : ''} aria-label={`Marcar ${c.customer_snapshot?.full_name ?? 'contrato'} para recalcular`} className="accent-[var(--brand)]" /></td>}
                    <td className="px-5 py-2.5">
                      <span className="block font-medium text-ink">{c.customer_snapshot?.full_name ?? '—'}</span>
                      <span className="text-xs text-muted">{formatCpf(c.customer_snapshot?.cpf)}{c.external_proposal_id ? ` · nº ${c.external_proposal_id}` : ''} · {new Date(c.created_at).toLocaleDateString('pt-BR')}</span>
                    </td>
                    <td className="px-3 py-2.5"><span className="block text-ink">{s?.name ?? '—'}</span><span className="text-xs text-muted">{s?.commission_group_id ? groupName.get(s.commission_group_id) ?? '' : 'sem grupo'}</span>{stale(c) && <Badge tone="pending" className="ml-1.5">Comissão desatualizada</Badge>}</td>
                    <td className="px-3 py-2.5"><span className="block text-ink">{bankName.get(w.bank) ?? '—'} · {agreementName.get(w.agreement) ?? '—'}</span><span className="text-xs text-muted">{w.table}{c.term ? ` · ${termText(c.term, c.term, c.term)}` : ''}</span></td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{brlText(String(c.requested_amount ?? c.released_amount ?? '0'))}{c.released_amount && c.released_amount !== c.requested_amount && <span className="block text-xs text-muted">líq. {brlText(String(c.released_amount))}</span>}</td>
                    <td className="whitespace-nowrap px-3 py-2.5"><Badge tone={STATUS_TONE[c.status] ?? 'neutral'}>{STATUS_LABEL[c.status] ?? c.status}</Badge></td>
                    {finance && (t ? <>
                      <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(t.get('received'))}</td>
                      <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(t.get('payable') ?? t.get('originator'))}{owner && payout.get(c.id)?.overridden && <Badge tone="pending" className="ml-1.5">Alterado</Badge>}
                        <span className="block text-[11px] text-muted">{(() => { const po = payout.get(c.id); return !po ? '' : po.paid_on ? `pago em ${new Date(`${po.paid_on}T12:00:00Z`).toLocaleDateString('pt-BR')}` : po.waiting === 'physical' ? 'aguardando físico' : po.waiting === 'client' ? 'aguardando pagamento ao cliente' : po.waiting === 'bank' ? 'aguardando comissão do banco' : po.waiting === 'divergent' ? 'comissão do banco divergente' : po.waiting === 'calculation' ? 'aguardando cálculo' : po.waiting === 'no_payout' ? 'concluído · sem repasse' : 'liberado, a pagar' })()}</span></td>
                      <td className={`num whitespace-nowrap px-3 py-2.5 text-right font-medium ${margin.startsWith('-') ? 'text-[#B91C1C]' : 'text-ink'}`}>{brlText(margin)}</td>
                    </> : <td colSpan={3} className="px-3 py-2.5 text-right"><Badge tone="pending">Comissão não calculada</Badge></td>)}
                    <td className="px-3 py-2.5 text-right"><Link href={`/app/propostas/${c.id}`} aria-label={`Abrir contrato de ${c.customer_snapshot?.full_name ?? 'cliente'}`} className="inline-flex size-8 items-center justify-center rounded-md text-muted hover:bg-surface-muted hover:text-ink"><ChevronRight size={16} aria-hidden /></Link></td>
                  </tr>
                )
              })}
              {!rows.length && <tr><td colSpan={10} className="px-5 py-8 text-center text-muted">
                <span className="block">{f.cliente ? 'Este cliente ainda não tem contrato.' : contracts.length ? 'Nenhum contrato com esses filtros.' : 'Nenhum contrato cadastrado ainda.'}</span>
                {canCreate && <span className="mt-3 inline-block">{newButton(f.cliente ? 'Cadastrar contrato para este cliente' : 'Cadastrar novo contrato')}</span>}
              </td></tr>}
            </tbody>
          </table>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm text-ink-soft">
          <span>{filtered.length ? `${(page - 1) * size + 1}–${Math.min(page * size, filtered.length)} de ${filtered.length}` : '0 contratos'}</span>
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
