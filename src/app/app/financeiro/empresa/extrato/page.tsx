import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, dayLabel, FIN_KIND_LABEL, toCents } from '@/lib/finance/labels'
import { FinanceTabs } from '../FinanceTabs'
import { entryFromLine, ignoreLine, matchLine, restoreLine, unmatchLine } from '../actions'
import { StatementImportClient } from './StatementImportClient'

type Line = { id: string; bank_account_id: string; posted_on: string; amount: string; memo: string | null }
type Entry = { id: string; direction: string; status: string; description: string; amount: string; due_on: string; settled_on: string | null; bank_account_id: string | null }
type Done = Line & { status: string; entry_id: string | null }
type DoneEntry = { id: string; description: string; status: string; due_on: string; source: string; source_ref: string | null }
const DONE: Record<string, string> = { todas: 'Todas', conciliadas: 'Conciliadas', ignoradas: 'Ignoradas' }
type Account = { id: string; code: string; name: string; kind: string; is_group: boolean; is_active: boolean }
const days = (a: string, b: string) => Math.abs(Date.parse(a) - Date.parse(b)) / 86_400_000

// Statement reconciliation: each pending line of the bank statement is matched to the entry with the same direction and
// amount (open, or settled without an account), turned into a new entry (a fee, an unregistered income) or ignored.
// Lines already handled can be undone (04/11/2026): reconciliation with a reason, ignored back to pending.
export default async function StatementPage({ searchParams }: { searchParams: Promise<{ tratadas?: string }> }) {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Extrato bancário" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  await supabase.rpc('fin_setup', { p_org: organization.id })
  const edit = can(access, 'financeiro.edit')
  const tratadas = (await searchParams).tratadas ?? ''
  const doneView = DONE[tratadas] ? tratadas : 'todas'
  let doneQ = supabase.from('fin_statement_lines').select('id,bank_account_id,posted_on,amount,memo,status,entry_id').order('posted_on', { ascending: false }).limit(100)
  doneQ = doneView === 'conciliadas' ? doneQ.eq('status', 'matched') : doneView === 'ignoradas' ? doneQ.eq('status', 'ignored') : doneQ.in('status', ['matched', 'ignored'])
  const [{ data: doneRows }, { data: banks }, { data: lines }, { data: candidates }, { data: accounts }, { data: branches }] = await Promise.all([
    doneQ,
    supabase.from('fin_bank_accounts').select('id,label,account_number').eq('is_active', true).order('label'),
    supabase.from('fin_statement_lines').select('id,bank_account_id,posted_on,amount,memo').eq('status', 'pending').order('posted_on').limit(300),
    supabase.from('fin_entries').select('id,direction,status,description,amount,due_on,settled_on,bank_account_id').or('status.eq.open,and(status.eq.settled,bank_account_id.is.null)').limit(2000),
    supabase.from('fin_chart_accounts').select('id,code,name,kind,is_group,is_active').order('code'),
    supabase.from('organization_branches').select('id,name').eq('is_active', true).order('name'),
  ])
  const done = (doneRows ?? []) as Done[]
  const doneIds = done.map(d => d.entry_id).filter((x): x is string => !!x)
  const { data: doneEntries } = doneIds.length ? await supabase.from('fin_entries').select('id,description,status,due_on,source,source_ref').in('id', doneIds) : { data: [] }
  const entryById = new Map(((doneEntries ?? []) as DoneEntry[]).map(e => [e.id, e]))
  const bankName = new Map((banks ?? []).map(b => [b.id, b.label]))
  const usable = ((accounts ?? []) as Account[]).filter(a => !a.is_group && a.is_active)
  const pool = (candidates ?? []) as Entry[]
  // Suggestions: same direction and amount, closest date first.
  const suggest = (l: Line) => pool
    .filter(e => (toCents(l.amount) > 0) === (e.direction === 'in') && Math.abs(toCents(l.amount)) === toCents(e.amount))
    .sort((a, b) => days(a.settled_on ?? a.due_on, l.posted_on) - days(b.settled_on ?? b.due_on, l.posted_on)).slice(0, 3)

  return (
    <section>
      <PageHeader title="Extrato bancário" description="Importe o extrato em OFX (C6 Bank, Banco do Brasil, Inter, PagSeguro) e concilie cada linha com um lançamento." />
      <FinanceTabs current="/app/financeiro/empresa/extrato" />
      {edit && <Card className="mb-4"><CardHeader title="Importar extrato" /><div className="px-5 pb-5"><StatementImportClient banks={banks ?? []} /></div></Card>}
      <Card className="overflow-hidden">
        <CardHeader title={`Linhas a conciliar (${(lines ?? []).length})`} />
        {!(lines ?? []).length ? <p className="px-5 pb-5 text-sm text-muted">Nenhuma linha pendente.</p> : (
          <ul>
            {((lines ?? []) as Line[]).map(l => {
              const sug = suggest(l)
              return (
                <li key={l.id} className="grid gap-2 border-t border-line px-5 py-3 lg:grid-cols-[1fr_1.6fr]">
                  <div>
                    <p className={`num text-sm font-medium ${Number(l.amount) > 0 ? 'text-[#15803D]' : 'text-ink'}`}>{Number(l.amount) > 0 ? '+' : '−'} {brl(Math.abs(Number(l.amount)))}</p>
                    <p className="text-xs text-muted">{dayLabel(l.posted_on)} · {bankName.get(l.bank_account_id)}</p>
                    <p className="text-sm text-ink-soft">{l.memo ?? '—'}</p>
                  </div>
                  {edit && (
                    <div className="grid gap-2">
                      {sug.map(e => (
                        <form key={e.id} action={matchLine} className="flex flex-wrap items-center justify-between gap-2 rounded-[10px] border border-line px-3 py-2 text-sm">
                          <input type="hidden" name="line_id" value={l.id} /><input type="hidden" name="entry_id" value={e.id} />
                          <span>{e.description} <span className="text-xs text-muted">· {e.status === 'open' ? `vence ${dayLabel(e.due_on)}` : `baixado ${dayLabel(e.settled_on)} sem conta`}</span></span>
                          <SubmitButton className="h-8 rounded-lg bg-brand px-3 text-xs font-semibold text-white" pendingText="...">Conciliar</SubmitButton>
                        </form>
                      ))}
                      <details className="text-sm">
                        <summary className="cursor-pointer text-xs text-muted underline">{sug.length ? 'Não é nenhum desses: criar lançamento' : 'Criar lançamento a partir desta linha'}</summary>
                        <form action={entryFromLine} className="mt-2 flex flex-wrap items-end gap-2">
                          <input type="hidden" name="line_id" value={l.id} />
                          <select name="account_id" required defaultValue="" aria-label="Conta do plano" className="field h-9 w-auto py-1">
                            <option value="" disabled>Conta do plano</option>
                            {Object.keys(FIN_KIND_LABEL).map(k => { const list = usable.filter(a => a.kind === k); return list.length ? <optgroup key={k} label={FIN_KIND_LABEL[k]}>{list.map(a => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</optgroup> : null })}
                          </select>
                          <select name="branch_id" aria-label="Filial" className="field h-9 w-auto py-1"><option value="">Empresa toda</option>{(branches ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
                          <input name="description" maxLength={200} placeholder={l.memo ?? 'Descrição'} aria-label="Descrição" className="field h-9 w-56 py-1" />
                          <SubmitButton className="h-9 rounded-lg border border-line-strong px-3 text-xs" pendingText="...">Criar</SubmitButton>
                        </form>
                      </details>
                      <form action={ignoreLine}><input type="hidden" name="line_id" value={l.id} /><button className="text-xs text-muted underline">Ignorar esta linha</button></form>
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
        )}
      </Card>
      <Card className="mt-4 overflow-hidden">
        <CardHeader title="Já tratadas (últimas 100)" action={
          <div className="flex gap-1.5">{Object.entries(DONE).map(([k, v]) => (
            <Link key={k} href={`/app/financeiro/empresa/extrato?tratadas=${k}`} aria-current={k === doneView ? 'page' : undefined}
              className={`rounded-[10px] border px-3 py-1 text-sm ${k === doneView ? 'border-ink bg-ink text-white' : 'border-line bg-surface text-ink-soft hover:bg-surface-muted'}`}>{v}</Link>
          ))}</div>} />
        {!done.length ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nenhuma linha tratada.</p> : (
          <ul className="mt-3">
            {done.map(l => {
              const e = l.entry_id ? entryById.get(l.entry_id) : undefined
              const created = !!e && e.source === 'statement' && e.source_ref === l.id
              return (
                <li key={l.id} className="grid gap-2 border-t border-line px-5 py-3 sm:grid-cols-[8rem_1fr_1.2fr_auto] sm:items-start">
                  <div>
                    <p className={`num text-sm font-medium ${Number(l.amount) > 0 ? 'text-[#15803D]' : 'text-ink'}`}>{Number(l.amount) > 0 ? '+' : '−'} {brl(Math.abs(Number(l.amount)))}</p>
                    <p className="text-xs text-muted">{dayLabel(l.posted_on)} · {bankName.get(l.bank_account_id)}</p>
                  </div>
                  <p className="text-sm text-ink-soft">{l.memo ?? '—'}</p>
                  <div className="text-sm">
                    {l.status === 'ignored' ? <Badge tone="neutral">Ignorada</Badge> : <Badge tone="received">{created ? 'Lançamento criado' : 'Conciliada'}</Badge>}
                    {e && <span className="mt-0.5 block text-xs text-ink-soft">{created ? `${e.description} · ao desfazer, o lançamento é cancelado` : `com ${e.description} (venc. ${dayLabel(e.due_on)})`}</span>}
                  </div>
                  {edit && (l.status === 'ignored' ? (
                    <form action={restoreLine} className="sm:text-right"><input type="hidden" name="line_id" value={l.id} />
                      <SubmitButton className="h-8 rounded-lg border border-line-strong px-3 text-xs" pendingText="...">Voltar para a conciliar</SubmitButton></form>
                  ) : (
                    <details className="sm:text-right">
                      <summary className="inline-flex h-8 cursor-pointer items-center rounded-lg border border-line-strong px-3 text-xs">Desfazer conciliação</summary>
                      <form action={unmatchLine} className="mt-2 grid gap-1.5 rounded-[10px] border border-line p-2.5 text-left sm:w-80">
                        <input type="hidden" name="line_id" value={l.id} />
                        <p className="text-xs text-ink-soft">A linha volta para a conciliar. {created ? 'O lançamento criado a partir dela é cancelado.' : 'O lançamento volta como estava antes (em aberto, se foi esta conciliação que o pagou).'}</p>
                        <div className="flex gap-1.5">
                          <input name="reason" required minLength={3} maxLength={200} placeholder="Motivo" aria-label="Motivo" className="field h-8 flex-1 py-0 text-xs" />
                          <SubmitButton className="h-8 rounded-lg bg-[#991B1B] px-3 text-xs font-semibold text-white" pendingText="...">Desfazer</SubmitButton>
                        </div>
                      </form>
                    </details>
                  ))}
                </li>
              )
            })}
          </ul>
        )}
      </Card>
    </section>
  )
}
