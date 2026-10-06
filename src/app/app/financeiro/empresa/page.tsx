import { Badge, Card, CardHeader, Kpi, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, dayLabel, FIN_KIND_LABEL, FIN_SOURCE_LABEL, FIN_STATUS_LABEL } from '@/lib/finance/labels'
import { FinanceTabs } from './FinanceTabs'
import { cancelEntry, createEntry, settleEntry, undoSettlement } from './actions'

type Entry = { id: string; direction: string; status: string; description: string; account_id: string; branch_id: string | null; counterpart: string | null; amount: string; due_on: string; settled_on: string | null; bank_account_id: string | null; source: string }
type Account = { id: string; code: string; name: string; kind: string; is_group: boolean; is_active: boolean }
const VIEWS: Record<string, string> = { pagar: 'A pagar', receber: 'A receber', baixados: 'Pagos e recebidos', todos: 'Todos' }
const label = 'text-[13px] font-medium text-ink-soft'
const today = () => new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 10)

// F6.5: payables and receivables of the company, with the branch as cost center.
export default async function CompanyFinancePage({ searchParams }: { searchParams: Promise<{ ver?: string; de?: string; ate?: string; filial?: string }> }) {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Financeiro da empresa" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  await supabase.rpc('fin_setup', { p_org: organization.id })
  const sp = await searchParams
  const view = VIEWS[sp.ver ?? ''] ? sp.ver! : 'pagar'
  const from = /^\d{4}-\d{2}-\d{2}$/.test(sp.de ?? '') ? sp.de! : null
  const to = /^\d{4}-\d{2}-\d{2}$/.test(sp.ate ?? '') ? sp.ate! : null
  const edit = can(access, 'financeiro.edit')

  let q = supabase.from('fin_entries').select('id,direction,status,description,account_id,branch_id,counterpart,amount,due_on,settled_on,bank_account_id,source').limit(300)
  if (view === 'pagar') q = q.eq('status', 'open').eq('direction', 'out').order('due_on')
  else if (view === 'receber') q = q.eq('status', 'open').eq('direction', 'in').order('due_on')
  else if (view === 'baixados') q = q.eq('status', 'settled').order('settled_on', { ascending: false })
  else q = q.order('due_on', { ascending: false })
  if (from) q = q.gte(view === 'baixados' ? 'settled_on' : 'due_on', from)
  if (to) q = q.lte(view === 'baixados' ? 'settled_on' : 'due_on', to)
  if (sp.filial) q = q.eq('branch_id', sp.filial)
  const [{ data: rows }, { data: accounts }, { data: branches }, { data: banks }, { data: balances }, { data: open }] = await Promise.all([
    q,
    supabase.from('fin_chart_accounts').select('id,code,name,kind,is_group,is_active').order('code'),
    supabase.from('organization_branches').select('id,name').eq('is_active', true).order('name'),
    supabase.from('fin_bank_accounts').select('id,label,bank_name').eq('is_active', true).order('label'),
    supabase.rpc('fin_bank_balances', { p_org: organization.id }),
    supabase.from('fin_entries').select('direction,amount,due_on').eq('status', 'open').limit(5000),
  ])
  const acc = new Map(((accounts ?? []) as Account[]).map(a => [a.id, a]))
  const branchName = new Map((branches ?? []).map(b => [b.id, b.name]))
  const bankName = new Map((banks ?? []).map(b => [b.id, b.label]))
  const sum = (xs: { amount: string }[]) => xs.reduce((s, x) => s + Math.round(Number(x.amount) * 100), 0) / 100
  const openRows = (open ?? []) as { direction: string; amount: string; due_on: string }[]
  const t = today()
  const usable = ((accounts ?? []) as Account[]).filter(a => !a.is_group && a.is_active)
  const back = `/app/financeiro/empresa?ver=${view}`

  return (
    <section>
      <PageHeader title="Financeiro da empresa" description="Contas a pagar e a receber, com a filial como centro de custo. Comissão recebida dos bancos e repasse pago entram sozinhos (ou pela lista a lançar)." />
      <FinanceTabs current="/app/financeiro/empresa" />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Kpi label="Saldo nas contas" value={brl(((balances ?? []) as { balance: string }[]).reduce((s, b) => s + Number(b.balance), 0))} />
        <Kpi label="A receber em aberto" value={brl(sum(openRows.filter(r => r.direction === 'in')))} />
        <Kpi label="A pagar em aberto" value={brl(sum(openRows.filter(r => r.direction === 'out')))} />
        <Kpi label="Vencidos a pagar" value={brl(sum(openRows.filter(r => r.direction === 'out' && r.due_on < t)))} />
      </div>

      {edit && (
        <Card className="mb-4">
          <details>
            <summary className="cursor-pointer px-5 py-4 text-sm font-semibold text-ink">+ Novo lançamento</summary>
            <form action={createEntry} className="grid gap-4 px-5 pb-5 sm:grid-cols-3">
              <input type="hidden" name="return_to" value={back} />
              <label className={label}>Tipo<select name="direction" className="field mt-1.5"><option value="out">A pagar (saída)</option><option value="in">A receber (entrada)</option></select></label>
              <label className={`${label} sm:col-span-2`}>Descrição<input name="description" required minLength={3} maxLength={200} className="field mt-1.5" /></label>
              <label className={label}>Conta do plano
                <select name="account_id" required defaultValue="" className="field mt-1.5">
                  <option value="" disabled>Escolha</option>
                  {Object.keys(FIN_KIND_LABEL).map(k => {
                    const list = usable.filter(a => a.kind === k)
                    return list.length ? <optgroup key={k} label={FIN_KIND_LABEL[k]}>{list.map(a => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</optgroup> : null
                  })}
                </select>
              </label>
              <label className={label}>Filial (centro de custo)<select name="branch_id" className="field mt-1.5"><option value="">Empresa toda</option>{(branches ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
              <label className={label}>Fornecedor ou cliente<input name="counterpart" maxLength={120} className="field mt-1.5" /></label>
              <label className={label}>Valor (R$)<input name="amount" required inputMode="decimal" placeholder="1.234,56" className="field mt-1.5" /></label>
              <label className={label}>Vencimento<input type="date" name="due_on" required defaultValue={t} className="field mt-1.5" /></label>
              <label className={label}>Como lançar
                <select name="plan" defaultValue="once" className="field mt-1.5">
                  <option value="once">Uma vez</option>
                  <option value="repeat">Repetir todo mês (mesmo valor)</option>
                  <option value="split">Parcelar (dividir o valor)</option>
                </select>
              </label>
              <label className={label}>Quantos meses <span className="font-normal text-muted">(repetir ou parcelar)</span><input type="number" name="installments" min={1} max={60} defaultValue={1} className="field mt-1.5" /></label>
              <p className="text-xs text-ink-soft sm:col-span-2">Repetir: o mesmo valor todo mês, por exemplo salário ou aluguel (R$ 1.000 por 3 meses = 3 × R$ 1.000). Parcelar: o valor é dividido (R$ 1.000 em 3 parcelas = 3 × R$ 333,33).</p>
              <label className={label}>Competência <span className="font-normal text-muted">(DRE; vazio = vencimento)</span><input type="date" name="competence_on" className="field mt-1.5" /></label>
              <label className={label}>Documento<input name="document" maxLength={60} className="field mt-1.5" /></label>
              <label className={label}>Conta bancária <span className="font-normal text-muted">(se já pago)</span><select name="bank_account_id" className="field mt-1.5"><option value="">—</option>{(banks ?? []).map(b => <option key={b.id} value={b.id}>{b.label}</option>)}</select></label>
              <label className="flex items-center gap-2 text-sm text-ink-soft sm:col-span-2"><input type="checkbox" name="settled" className="size-4 accent-[var(--brand)]" />Já foi pago ou recebido (baixa na data do vencimento)</label>
              <div className="flex justify-end"><SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Registrar</SubmitButton></div>
            </form>
          </details>
        </Card>
      )}

      <Card className="overflow-hidden">
        <CardHeader title={VIEWS[view]} action={
          <form className="flex flex-wrap items-end gap-2" action="/app/financeiro/empresa">
            <select name="ver" defaultValue={view} aria-label="Ver" className="field h-9 w-auto py-1">{Object.entries(VIEWS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
            <input type="date" name="de" defaultValue={from ?? ''} aria-label="De" className="field h-9 w-auto py-1" />
            <input type="date" name="ate" defaultValue={to ?? ''} aria-label="Até" className="field h-9 w-auto py-1" />
            <select name="filial" defaultValue={sp.filial ?? ''} aria-label="Filial" className="field h-9 w-auto py-1"><option value="">Todas as filiais</option>{(branches ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
            <button className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong">Filtrar</button>
          </form>} />
        {!(rows ?? []).length ? <p className="px-5 pb-5 text-sm text-muted">Nada por aqui.</p> : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-surface-muted text-xs text-muted"><tr>
                <th className="px-4 py-2">{view === 'baixados' ? 'Baixa' : 'Vencimento'}</th><th className="px-4 py-2">Descrição</th><th className="px-4 py-2">Conta</th>
                <th className="px-4 py-2">Filial</th><th className="px-4 py-2 text-right">Valor</th><th className="px-4 py-2">Situação</th><th className="px-4 py-2"><span className="sr-only">Ações</span></th>
              </tr></thead>
              <tbody>
                {((rows ?? []) as Entry[]).map(e => {
                  const a = acc.get(e.account_id)
                  const late = e.status === 'open' && e.due_on < t
                  return (
                    <tr key={e.id} className="border-t border-line align-top">
                      <td className={`num px-4 py-2 ${late ? 'text-[#B91C1C]' : 'text-ink-soft'}`}>{dayLabel(e.status === 'settled' ? e.settled_on : e.due_on)}</td>
                      <td className="px-4 py-2 text-ink">{e.description}{e.counterpart ? <span className="block text-xs text-muted">{e.counterpart}</span> : null}{e.source !== 'manual' ? <span className="block text-xs text-muted">{FIN_SOURCE_LABEL[e.source]}</span> : null}</td>
                      <td className="px-4 py-2 text-ink-soft">{a ? `${a.code} ${a.name}` : '—'}</td>
                      <td className="px-4 py-2 text-ink-soft">{e.branch_id ? branchName.get(e.branch_id) ?? '—' : 'Empresa toda'}</td>
                      <td className={`num px-4 py-2 text-right ${e.direction === 'in' ? 'text-[#15803D]' : 'text-ink'}`}>{e.direction === 'in' ? '+' : '−'} {brl(e.amount)}</td>
                      <td className="px-4 py-2"><Badge tone={e.status === 'settled' ? 'received' : e.status === 'cancelled' ? 'neutral' : late ? 'diverged' : 'pending'}>{late ? 'Vencido' : FIN_STATUS_LABEL[e.status]}</Badge>{e.bank_account_id ? <span className="block text-xs text-muted">{bankName.get(e.bank_account_id)}</span> : null}</td>
                      <td className="px-4 py-2">
                        {edit && e.status === 'open' && (
                          <div className="flex flex-col gap-1">
                            <form action={settleEntry} className="flex flex-wrap items-center gap-1">
                              <input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                              <input type="date" name="settled_on" required defaultValue={t} aria-label="Data da baixa" className="field h-8 w-auto py-0 text-xs" />
                              <select name="bank_account_id" aria-label="Conta bancária" className="field h-8 w-auto py-0 text-xs"><option value="">Conta?</option>{(banks ?? []).map(b => <option key={b.id} value={b.id}>{b.label}</option>)}</select>
                              <SubmitButton className="h-8 rounded-lg bg-brand px-2.5 text-xs font-semibold text-white" pendingText="...">{e.direction === 'in' ? 'Receber' : 'Pagar'}</SubmitButton>
                            </form>
                            <details className="text-xs"><summary className="cursor-pointer text-muted underline">Cancelar</summary>
                              <form action={cancelEntry} className="mt-1 flex gap-1"><input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                                <input name="reason" required minLength={3} placeholder="Motivo" aria-label="Motivo do cancelamento" className="field h-8 py-0 text-xs" /><button className="rounded-lg border border-line px-2 text-xs">Cancelar</button></form>
                            </details>
                          </div>
                        )}
                        {edit && e.status === 'settled' && e.source === 'manual' && (
                          <details className="text-xs"><summary className="cursor-pointer text-muted underline">Desfazer baixa</summary>
                            <form action={undoSettlement} className="mt-1 flex gap-1"><input type="hidden" name="return_to" value={back} /><input type="hidden" name="entry_id" value={e.id} />
                              <input name="reason" required minLength={3} placeholder="Motivo" aria-label="Motivo para desfazer" className="field h-8 py-0 text-xs" /><button className="rounded-lg border border-line px-2 text-xs">Desfazer</button></form>
                          </details>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </section>
  )
}
