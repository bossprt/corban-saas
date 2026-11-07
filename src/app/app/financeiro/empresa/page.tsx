import Link from 'next/link'
import { Paperclip, Plus, Search, SlidersHorizontal } from 'lucide-react'
import { Badge, Card, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, brlCents, centsToDecimal, dayLabel, toCents, FIN_KIND_LABEL, FIN_SOURCE_LABEL, FIN_STATUS_LABEL } from '@/lib/finance/labels'
import { entrySearchFilter } from '@/lib/finance/search'
import { isUuid } from '@/lib/team'
import { FinanceTabs } from './FinanceTabs'
import { NewEntryForm } from './NewEntryForm'
import { SelectedTotal } from './SelectedTotal'
import { addReceipt, cancelEntry, settleEntry, settleMany, undoSettlement, updateEntry } from './actions'
import { SettleForm } from './SettleForm'
import { addDaysISO, todaySP } from '@/lib/dates'

type Entry = { id: string; direction: string; status: string; description: string; account_id: string; branch_id: string | null; counterpart: string | null; document: string | null; amount: string; due_on: string; competence_on: string; settled_on: string | null; bank_account_id: string | null; source: string; interest: string; discount: string; original_amount: string | null }
type Account = { id: string; code: string; name: string; kind: string; is_group: boolean; is_active: boolean }
type EntryEvent = { id: string; kind: string; detail: Record<string, { from: unknown; to: unknown }>; reason: string | null; created_at: string }
const dv = (ev: EntryEvent, k: string) => (ev.detail as Record<string, unknown> | null)?.[k]
const VIEWS: Record<string, string> = { pagar: 'A pagar', receber: 'A receber', baixados: 'Pagos e recebidos', todos: 'Todos' }
const EVENT_LABEL: Record<string, string> = { created: 'Lançado', edited: 'Alterado', settled: 'Baixado', settlement_undone: 'Baixa desfeita', cancelled: 'Cancelado', reconciled: 'Conciliado com o extrato', reconciliation_undone: 'Conciliação desfeita', receipt_added: 'Comprovante anexado' }
const FIELD_LABEL: Record<string, string> = { description: 'Descrição', account: 'Conta do plano', branch: 'Filial', amount: 'Valor', due_on: 'Vencimento', competence_on: 'Competência' }
const label = 'text-[13px] font-medium text-ink-soft'
const BULK = 'pagar-varios'
const today = () => todaySP()
const addDays = addDaysISO
// numeric(15,2) comes as text: cents without going through a float.
const cents = toCents
const sumCents = (xs: { amount: string }[]) => xs.reduce((s, x) => s + cents(x.amount), 0)
const moneyField = (v: string) => centsToDecimal(cents(v)).replace('.', ',')

// F6.5: payables and receivables of the company, with the branch as cost center. Layout reviewed 04/11/2026: what is
// late or due first, one "Pagar" per line, the rest of the actions under "⋯", edit and history inline.
export default async function CompanyFinancePage({ searchParams }: { searchParams: Promise<{ ver?: string; busca?: string; de?: string; ate?: string; filial?: string; conta?: string; cancelados?: string; novo?: string; alterar?: string; historico?: string }> }) {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Financeiro da empresa" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  await supabase.rpc('fin_setup', { p_org: organization.id })
  const sp = await searchParams
  const view = VIEWS[sp.ver ?? ''] ? sp.ver! : 'pagar'
  const from = /^\d{4}-\d{2}-\d{2}$/.test(sp.de ?? '') ? sp.de! : null
  const to = /^\d{4}-\d{2}-\d{2}$/.test(sp.ate ?? '') ? sp.ate! : null
  const filial = isUuid(sp.filial ?? '') ? sp.filial! : null
  const conta = isUuid(sp.conta ?? '') ? sp.conta! : null
  const cancelled = sp.cancelados === '1'
  const busca = String(sp.busca ?? '').trim().slice(0, 80)
  const searchFilter = entrySearchFilter(busca)
  const editing = isUuid(sp.alterar ?? '') ? sp.alterar! : null
  const history = isUuid(sp.historico ?? '') ? sp.historico! : null
  const edit = can(access, 'financeiro.edit')
  const t = today()

  let q = supabase.from('fin_entries').select('id,direction,status,description,account_id,branch_id,counterpart,document,amount,due_on,competence_on,settled_on,bank_account_id,source,interest,discount,original_amount').limit(300)
  if (view === 'pagar') q = q.eq('status', 'open').eq('direction', 'out').order('due_on')
  else if (view === 'receber') q = q.eq('status', 'open').eq('direction', 'in').order('due_on')
  else if (view === 'baixados') q = q.eq('status', 'settled').order('settled_on', { ascending: false })
  else { q = q.order('due_on', { ascending: false }); if (!cancelled) q = q.neq('status', 'cancelled') }
  if (from) q = q.gte(view === 'baixados' ? 'settled_on' : 'due_on', from)
  if (to) q = q.lte(view === 'baixados' ? 'settled_on' : 'due_on', to)
  if (filial) q = q.eq('branch_id', filial)
  // Company bank account (07/10/2026): only entries paid or received in it.
  if (conta) q = q.eq('bank_account_id', conta)
  // Buscar (05/11/2026): within the open tab and the other filters.
  if (searchFilter) q = q.or(searchFilter)
  const [{ data: rows }, { data: accounts }, { data: branches }, { data: banks }, { data: balances }, { data: open }, { data: lastPaid }, { data: events }] = await Promise.all([
    q,
    supabase.from('fin_chart_accounts').select('id,code,name,kind,is_group,is_active').order('code'),
    supabase.from('organization_branches').select('id,name').eq('is_active', true).order('name'),
    supabase.from('fin_bank_accounts').select('id,label,bank_name').eq('is_active', true).order('label'),
    supabase.rpc('fin_bank_balances', { p_org: organization.id }),
    supabase.from('fin_entries').select('direction,amount,due_on').eq('status', 'open').limit(5000),
    // "Pagar" starts on the bank account used last.
    supabase.from('fin_entries').select('bank_account_id').eq('status', 'settled').not('bank_account_id', 'is', null).order('updated_at', { ascending: false }).limit(1),
    history ? supabase.from('fin_entry_events').select('id,kind,detail,reason,created_at').eq('entry_id', history).order('created_at') : Promise.resolve({ data: [] }),
  ])
  const list = (rows ?? []) as Entry[]
  // Receipts of the listed entries, opened by a short-lived signed link (private storage).
  const { data: receiptRows } = list.length ? await supabase.from('fin_entry_receipts').select('entry_id,storage_path,file_name').in('entry_id', list.map(e => e.id)).order('created_at') : { data: [] }
  const receipts = (receiptRows ?? []) as { entry_id: string; storage_path: string; file_name: string }[]
  const { data: signed } = receipts.length ? await supabase.storage.from('fin-receipts').createSignedUrls(receipts.map(r => r.storage_path), 600) : { data: [] }
  const receiptsOf = new Map<string, { name: string; url: string }[]>()
  receipts.forEach((r, i) => { const url = signed?.[i]?.signedUrl; if (url) receiptsOf.set(r.entry_id, [...(receiptsOf.get(r.entry_id) ?? []), { name: r.file_name, url }]) })
  const acc = new Map(((accounts ?? []) as Account[]).map(a => [a.id, a]))
  const branchName = new Map((branches ?? []).map(b => [b.id, b.name]))
  const bankName = new Map((banks ?? []).map(b => [b.id, b.label]))
  const lastBank = (lastPaid ?? [])[0]?.bank_account_id as string | undefined
  const defaultBank = lastBank && bankName.has(lastBank) ? lastBank : ''
  const openRows = (open ?? []) as { direction: string; amount: string; due_on: string }[]
  const openOut = openRows.filter(r => r.direction === 'out')
  const late = openOut.filter(r => r.due_on < t)
  const week = addDays(t, 7)
  const soon = openOut.filter(r => r.due_on >= t && r.due_on <= week)
  const usable = ((accounts ?? []) as Account[]).filter(a => !a.is_group && a.is_active)
  const listQs = new URLSearchParams(Object.entries({ ver: view, busca, de: from ?? '', ate: to ?? '', filial: filial ?? '', conta: conta ?? '', cancelados: cancelled ? '1' : '' }).filter(([, v]) => v)).toString()
  const back = `/app/financeiro/empresa?${listQs}`
  const viewHref = (v: string) => `/app/financeiro/empresa?ver=${v}`
  const count: Record<string, number> = { pagar: openOut.length, receber: openRows.length - openOut.length }
  const moreFilters = !!(from || to || filial || conta || cancelled)
  const bankOptions = (banks ?? []).map(b => <option key={b.id} value={b.id}>{b.label}</option>)
  const accountOptions = Object.keys(FIN_KIND_LABEL).map(k => {
    const group = usable.filter(a => a.kind === k)
    return group.length ? <optgroup key={k} label={FIN_KIND_LABEL[k]}>{group.map(a => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</optgroup> : null
  })
  const showChange = (k: string, v: unknown) =>
    v === null || v === undefined ? '—' : k === 'amount' ? brl(String(v)) : k === 'due_on' || k === 'competence_on' ? dayLabel(String(v))
      : k === 'account' ? (acc.get(String(v)) ? `${acc.get(String(v))!.code} ${acc.get(String(v))!.name}` : '—') : k === 'branch' ? branchName.get(String(v)) ?? '—' : String(v)
  const kpi = (title: string, value: string, hint: string | null, tone: 'late' | 'soon' | 'plain', href?: string) => {
    const cls = tone === 'late' ? 'border-[#F7C1C1] bg-[#FCEBEB] text-[#991B1B]' : tone === 'soon' ? 'border-[#FAC775] bg-[#FAEEDA] text-[#854F0B]' : 'border-line bg-surface text-ink'
    const body = <><span className="text-[13px] font-medium opacity-90">{title}</span><span className="num text-[26px] font-semibold tracking-tight">{value}</span>{hint ? <span className="text-[13px] underline-offset-2 group-hover:underline">{hint}</span> : null}</>
    return href ? <Link href={href} className={`group flex flex-col gap-1 rounded-[14px] border px-5 py-4 ${cls}`}>{body}</Link> : <div className={`flex flex-col gap-1 rounded-[14px] border px-5 py-4 ${cls}`}>{body}</div>
  }

  return (
    <section>
      <PageHeader title="Financeiro da empresa" description="Contas a pagar e a receber, com a filial como centro de custo. Comissão recebida dos bancos e repasse pago entram sozinhos (ou pela lista a lançar)."
        actions={edit ? <Link href={`${back}&novo=1#novo`} className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Plus size={16} aria-hidden />Novo lançamento</Link> : null} />
      <FinanceTabs current="/app/financeiro/empresa" />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {kpi('Vencidos a pagar', brlCents(sumCents(late)), late.length ? `${late.length} conta(s) · ver` : null, late.length ? 'late' : 'plain', late.length ? `/app/financeiro/empresa?ver=pagar&ate=${addDays(t, -1)}` : undefined)}
        {kpi('Vence hoje e em 7 dias', brlCents(sumCents(soon)), soon.length ? `${soon.length} conta(s) · ver` : null, soon.length ? 'soon' : 'plain', soon.length ? `/app/financeiro/empresa?ver=pagar&de=${t}&ate=${week}` : undefined)}
        {kpi('A receber em aberto', brlCents(sumCents(openRows.filter(r => r.direction === 'in'))), null, 'plain')}
        {kpi('Saldo nas contas', brlCents(((balances ?? []) as { balance: string }[]).reduce((s, b) => s + cents(String(b.balance)), 0)), null, 'plain')}
      </div>

      {edit && (
        <Card className="mb-4">
          <details id="novo" open={sp.novo === '1'}>
            <summary className="cursor-pointer px-5 py-4 text-sm font-semibold text-ink">+ Novo lançamento</summary>
            <NewEntryForm back={back} today={t} defaultBank={defaultBank} accountOptions={accountOptions} bankOptions={bankOptions} branches={branches ?? []} />
          </details>
        </Card>
      )}

      <div className="mb-3 flex flex-wrap items-center gap-1.5">
        {Object.entries(VIEWS).map(([k, v]) => (
          <Link key={k} href={busca ? `${viewHref(k)}&busca=${encodeURIComponent(busca)}` : viewHref(k)} aria-current={k === view ? 'page' : undefined}
            className={`rounded-[10px] border px-3 py-1.5 text-sm ${k === view ? 'border-ink bg-ink text-white' : 'border-line bg-surface text-ink-soft hover:bg-surface-muted'}`}>
            {v}{count[k] !== undefined ? ` · ${count[k]}` : ''}
          </Link>
        ))}
        <form className="flex min-w-[16rem] flex-1 items-center gap-1.5 sm:ml-3" action="/app/financeiro/empresa" role="search">
          <input type="hidden" name="ver" value={view} />
          {from && <input type="hidden" name="de" value={from} />}{to && <input type="hidden" name="ate" value={to} />}
          {filial && <input type="hidden" name="filial" value={filial} />}{conta && <input type="hidden" name="conta" value={conta} />}
          {cancelled && <input type="hidden" name="cancelados" value="1" />}
          <span className="relative min-w-0 flex-1">
            <Search size={15} aria-hidden className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
            <input type="search" name="busca" defaultValue={busca} maxLength={80} placeholder="Buscar descrição, fornecedor, documento ou valor" aria-label="Buscar lançamentos" className="field h-9 w-full py-1 pl-9" />
          </span>
          <button className="inline-flex h-9 items-center rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted">Buscar</button>
          {busca && <Link href={`/app/financeiro/empresa?${new URLSearchParams(Object.entries({ ver: view, de: from ?? '', ate: to ?? '', filial: filial ?? '', conta: conta ?? '', cancelados: cancelled ? '1' : '' }).filter(([, v]) => v)).toString()}`} className="inline-flex h-9 items-center px-1 text-sm text-muted underline">Limpar</Link>}
        </form>
        <details className="ml-auto" open={moreFilters}>
          <summary className="inline-flex cursor-pointer items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 py-1.5 text-sm text-ink-soft hover:bg-surface-muted"><SlidersHorizontal size={14} aria-hidden />Mais filtros</summary>
          <form className="mt-2 flex flex-wrap items-end gap-2" action="/app/financeiro/empresa">
            <input type="hidden" name="ver" value={view} />
            {busca && <input type="hidden" name="busca" value={busca} />}
            <label className="text-xs text-muted">De<input type="date" name="de" defaultValue={from ?? ''} className="field mt-1 block h-9 w-auto py-1" /></label>
            <label className="text-xs text-muted">Até<input type="date" name="ate" defaultValue={to ?? ''} className="field mt-1 block h-9 w-auto py-1" /></label>
            <select name="filial" defaultValue={filial ?? ''} aria-label="Filial" className="field h-9 w-auto py-1"><option value="">Todas as filiais</option>{(branches ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
            <select name="conta" defaultValue={conta ?? ''} aria-label="Conta bancária" className="field h-9 w-auto py-1"><option value="">Todas as contas</option>{bankOptions}</select>
            {view === 'todos' && <label className="flex h-9 items-center gap-1.5 text-sm text-ink-soft"><input type="checkbox" name="cancelados" value="1" defaultChecked={cancelled} className="size-4" />Mostrar cancelados</label>}
            <button className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong">Filtrar</button>
            {moreFilters && <Link href={viewHref(view)} className="inline-flex h-9 items-center px-2 text-sm text-muted underline">Limpar</Link>}
          </form>
        </details>
      </div>

      <Card className="overflow-hidden">
        {busca && <p className="border-b border-line px-5 py-2.5 text-sm text-ink-soft">{list.length === 300 ? 'Mais de 300' : list.length} lançamento(s) encontrado(s) para &quot;{busca}&quot; em {VIEWS[view]}.</p>}
        {!list.length ? <p className="px-5 py-6 text-sm text-muted">{busca ? 'Nada encontrado nesta aba. Tente outra palavra ou a aba Todos.' : 'Nada por aqui.'}</p> : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-surface-muted text-xs text-muted"><tr>
                <th className="w-8 px-3 py-2"><span className="sr-only">Marcar</span></th>
                <th className="px-3 py-2">Situação</th><th className="px-3 py-2">Descrição</th><th className="px-3 py-2 text-right">Valor</th>
                <th className="px-3 py-2">Conta</th><th className="px-3 py-2"><span className="sr-only">Ações</span></th>
              </tr></thead>
              <tbody>
                {list.map(e => {
                  const a = acc.get(e.account_id)
                  const isLate = e.status === 'open' && e.due_on < t
                  const dueToday = e.status === 'open' && e.due_on === t
                  const isEditing = edit && editing === e.id && e.status === 'open'
                  const rowHref = (k: string) => `${back}&${k}=${e.id}#l-${e.id}`
                  return [
                    <tr key={e.id} id={`l-${e.id}`} className={`border-t border-line align-top ${isEditing || history === e.id ? 'bg-surface-muted/60' : ''}`}>
                      <td className="px-3 py-2.5">{edit && e.status === 'open' && <input type="checkbox" name="entry_ids" value={e.id} form={BULK} data-cents={cents(e.amount)} aria-label={`Marcar ${e.description}`} className="size-4 accent-[var(--brand)]" />}</td>
                      <td className="px-3 py-2.5">
                        <Badge tone={e.status === 'settled' ? 'received' : e.status === 'cancelled' ? 'neutral' : isLate ? 'reversed' : dueToday ? 'diverged' : 'pending'}>{isLate ? 'Vencido' : dueToday ? 'Vence hoje' : FIN_STATUS_LABEL[e.status]}</Badge>
                        <span className={`num mt-0.5 block text-xs ${isLate ? 'text-[#B91C1C]' : 'text-muted'}`}>{dayLabel(e.status === 'settled' ? e.settled_on : e.due_on)}</span>
                      </td>
                      <td className="px-3 py-2.5 text-ink">{e.description}{e.counterpart ? <span className="block text-xs text-muted">{e.counterpart}</span> : null}{e.source !== 'manual' ? <span className="block text-xs text-muted">{FIN_SOURCE_LABEL[e.source]}</span> : null}
                        {(receiptsOf.get(e.id) ?? []).map((r, i) => <a key={i} href={r.url} target="_blank" rel="noopener noreferrer" className="mt-0.5 inline-flex items-center gap-1 text-xs text-brand underline"><Paperclip size={12} aria-hidden />{r.name}</a>)}</td>
                      <td className={`num whitespace-nowrap px-3 py-2.5 text-right ${e.direction === 'in' ? 'text-[#15803D]' : 'text-ink'}`}>{e.direction === 'in' ? '+' : '−'} {brlCents(cents(e.amount) + cents(e.interest) - cents(e.discount))}
                        {(cents(e.interest) > 0 || cents(e.discount) > 0) && <span className="block text-xs text-muted">{brl(e.amount)}{cents(e.interest) > 0 ? ` + juros ${brl(e.interest)}` : ''}{cents(e.discount) > 0 ? ` − desc. ${brl(e.discount)}` : ''}</span>}
                        {e.original_amount && <span className="block text-xs text-muted">parcial de {brl(e.original_amount)}</span>}</td>
                      <td className="px-3 py-2.5 text-ink-soft">{a ? `${a.code} ${a.name}` : '—'}<span className="block text-xs text-muted">{e.branch_id ? branchName.get(e.branch_id) ?? '—' : 'Empresa toda'}{e.bank_account_id ? ` · ${bankName.get(e.bank_account_id) ?? ''}` : ''}</span></td>
                      <td className="px-3 py-2.5">
                        <div className="flex flex-col items-end gap-1">
                          {edit && e.status === 'open' && (
                            <details>
                              <summary className="inline-flex h-8 cursor-pointer items-center rounded-lg bg-brand px-3 text-xs font-semibold text-white">{e.direction === 'in' ? 'Receber' : 'Pagar'}</summary>
                              <SettleForm action={settleEntry} entryId={e.id} returnTo={back} amountCents={cents(e.amount)} direction={e.direction} manual={e.source === 'manual'}
                                today={t} defaultBank={defaultBank} bankOptions={bankOptions} />
                            </details>
                          )}
                          <details className="text-right text-xs">
                            <summary aria-label="Mais ações" className="inline-flex h-8 cursor-pointer items-center rounded-lg border border-line px-2.5 text-ink-soft hover:bg-surface-muted">⋯</summary>
                            <div className="mt-1 flex flex-col items-end gap-1">
                              {edit && e.status === 'open' && <Link href={rowHref('alterar')} className="text-ink underline">Alterar</Link>}
                              <Link href={rowHref('historico')} className="text-ink underline">Histórico</Link>
                              {edit && e.status === 'open' && (
                                <form action={cancelEntry} className="flex gap-1"><input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                                  <input name="reason" required minLength={3} placeholder="Motivo" aria-label="Motivo do cancelamento" className="field h-8 py-0 text-xs" /><button className="rounded-lg border border-line px-2 text-xs text-[#991B1B]">Cancelar</button></form>
                              )}
                              {edit && e.status !== 'cancelled' && (
                                <form action={addReceipt} className="flex items-center gap-1"><input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                                  <input type="file" name="receipt" required accept="application/pdf,image/jpeg,image/png,image/webp" aria-label="Comprovante" className="w-44 text-xs" /><button className="rounded-lg border border-line px-2 py-1 text-xs">Anexar comprovante</button></form>
                              )}
                              {edit && e.status === 'settled' && e.source === 'manual' && (
                                <form action={undoSettlement} className="flex gap-1"><input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                                  <input name="reason" required minLength={3} placeholder="Motivo" aria-label="Motivo para desfazer" className="field h-8 py-0 text-xs" /><button className="rounded-lg border border-line px-2 text-xs">Desfazer baixa</button></form>
                              )}
                            </div>
                          </details>
                        </div>
                      </td>
                    </tr>,
                    isEditing && (
                      <tr key={`${e.id}-edit`} className="bg-surface-muted/60"><td colSpan={6} className="px-4 pb-4">
                        <form action={updateEntry} className="grid gap-3 rounded-[12px] border border-brand bg-surface p-4 sm:grid-cols-3">
                          <input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                          <p className="text-sm font-semibold text-ink sm:col-span-3">Alterar lançamento · {e.description}</p>
                          <label className={label}>Valor (R$)<input name="amount" required inputMode="decimal" defaultValue={moneyField(e.amount)} readOnly={e.source !== 'manual'} className="field mt-1.5" />
                            {e.source !== 'manual' && <span className="mt-1 block text-xs font-normal text-muted">Lançamento automático: o valor vem da origem.</span>}</label>
                          <label className={label}>Vencimento<input type="date" name="due_on" required defaultValue={e.due_on} className="field mt-1.5" /></label>
                          <label className={label}>Descrição<input name="description" required minLength={3} maxLength={200} defaultValue={e.description} className="field mt-1.5" /></label>
                          <label className={label}>Fornecedor ou cliente<input name="counterpart" maxLength={120} defaultValue={e.counterpart ?? ''} className="field mt-1.5" /></label>
                          <label className={label}>Conta do plano<select name="account_id" required defaultValue={e.account_id} className="field mt-1.5">{accountOptions}</select></label>
                          <label className={label}>Filial<select name="branch_id" defaultValue={e.branch_id ?? ''} className="field mt-1.5"><option value="">Empresa toda</option>{(branches ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
                          <label className={label}>Competência <span className="font-normal text-muted">(DRE)</span><input type="date" name="competence_on" defaultValue={e.competence_on} className="field mt-1.5" /></label>
                          <label className={label}>Documento<input name="document" maxLength={60} defaultValue={e.document ?? ''} className="field mt-1.5" /></label>
                          <label className={label}>Motivo da alteração<input name="reason" required minLength={3} maxLength={200} placeholder="Reajuste do plano" className="field mt-1.5" /></label>
                          <p className="self-end text-xs text-muted sm:col-span-2">O valor antes e depois fica no histórico do lançamento.</p>
                          <div className="flex items-end justify-end gap-2">
                            <Link href={`${back}#l-${e.id}`} className="inline-flex h-10 items-center rounded-[10px] border border-line px-4 text-sm text-ink-soft">Fechar</Link>
                            <SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Salvar</SubmitButton>
                          </div>
                        </form>
                      </td></tr>
                    ),
                    history === e.id && (
                      <tr key={`${e.id}-hist`} className="bg-surface-muted/60"><td colSpan={6} className="px-4 pb-4">
                        <div className="rounded-[12px] border border-line bg-surface p-4 text-sm">
                          <div className="mb-2 flex items-center justify-between"><p className="font-semibold text-ink">Histórico · {e.description}</p><Link href={`${back}#l-${e.id}`} className="text-xs text-muted underline">Fechar</Link></div>
                          {!(events ?? []).length ? <p className="text-muted">Sem registros.</p> : (
                            <ul className="space-y-1.5">
                              {((events ?? []) as EntryEvent[]).map(ev => (
                                <li key={ev.id} className="text-ink-soft">
                                  <span className="num text-xs text-muted">{new Date(ev.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' })}</span>{' '}
                                  <span className="font-medium text-ink">{EVENT_LABEL[ev.kind] ?? ev.kind}</span>
                                  {ev.kind === 'edited' && Object.entries(ev.detail ?? {}).map(([k, c]) => FIELD_LABEL[k] && c && typeof c === 'object' ? <span key={k} className="block pl-4 text-xs">{FIELD_LABEL[k]}: {showChange(k, c.from)} → {showChange(k, c.to)}</span> : null)}
                                  {ev.kind === 'settled' && dv(ev, 'paid') != null && <span className="block pl-4 text-xs">Valor movimentado {brl(String(dv(ev, 'paid')))}{Number(dv(ev, 'interest')) > 0 ? ` · juros e multa ${brl(String(dv(ev, 'interest')))}` : ''}{Number(dv(ev, 'discount')) > 0 ? ` · desconto ${brl(String(dv(ev, 'discount')))}` : ''}{dv(ev, 'remainder') ? ' · restante ficou em aberto' : ''}</span>}
                                  {ev.kind === 'created' && dv(ev, 'remainder_of') ? <span className="block pl-4 text-xs">Restante de um pagamento parcial</span> : null}
                                  {ev.kind === 'receipt_added' && dv(ev, 'file') ? <span className="block pl-4 text-xs">{String(dv(ev, 'file'))}</span> : null}
                                  {ev.reason ? <span className="block pl-4 text-xs">Motivo: {ev.reason}</span> : null}
                                </li>
                              ))}
                            </ul>
                          )}
                        </div>
                      </td></tr>
                    ),
                  ]
                })}
              </tbody>
            </table>
          </div>
        )}
        {list.length === 300 && <p className="border-t border-line px-5 py-3 text-xs text-muted">Mostrando os primeiros 300. Use “Mais filtros” (datas, filial, conta) para ver o restante.</p>}
        {edit && list.some(e => e.status === 'open') && (
          <form id={BULK} action={settleMany} className="flex flex-wrap items-center justify-between gap-2 border-t border-line bg-surface-muted px-4 py-3">
            <input type="hidden" name="return_to" value={back} />
            <SelectedTotal form={BULK} />
            <div className="flex flex-wrap items-center gap-1.5">
              <input type="date" name="settled_on" required defaultValue={t} max={t} aria-label="Data da baixa" className="field h-9 w-auto py-1 text-sm" />
              <select name="bank_account_id" defaultValue={defaultBank} aria-label="Conta bancária" className="field h-9 w-auto py-1 text-sm"><option value="">Conta?</option>{bankOptions}</select>
              <SubmitButton className="h-9 rounded-[10px] border border-line-strong bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-muted" pendingText="Baixando...">Pagar ou receber selecionadas</SubmitButton>
            </div>
          </form>
        )}
      </Card>
    </section>
  )
}
