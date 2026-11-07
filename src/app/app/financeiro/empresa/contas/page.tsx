import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, centsToDecimal, dayLabel, FIN_BANKS, toCents } from '@/lib/finance/labels'
import { FinanceTabs } from '../FinanceTabs'
import { saveBankAccount } from '../actions'

type BankEvent = { id: string; bank_account_id: string; kind: string; detail: Record<string, unknown>; reason: string | null; created_at: string }
const EVENT_LABEL: Record<string, string> = { created: 'Conta criada', opening_changed: 'Saldo inicial alterado', activated: 'Conta ativada', deactivated: 'Conta desativada' }
type Bank = { id: string; bank_name: string; label: string; agency: string | null; account_number: string | null; opening_balance: string; opening_on: string; is_active: boolean }
const label = 'text-[13px] font-medium text-ink-soft'
const moneyText = (v: string) => brl(centsToDecimal(toCents(v))).replace(/^(-?)R\$\s/, '$1')

// Company bank accounts: opening balance and the balance from the settled entries. Changing the opening balance or its
// date asks for a reason and stays in the account history (04/11/2026).
export default async function BankAccountsPage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Contas bancárias" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const edit = can(access, 'financeiro.edit')
  const [{ data: banks }, { data: balances }, { data: events }] = await Promise.all([
    supabase.from('fin_bank_accounts').select('id,bank_name,label,agency,account_number,opening_balance,opening_on,is_active').order('label'),
    supabase.rpc('fin_bank_balances', { p_org: organization.id }),
    supabase.from('fin_bank_account_events').select('id,bank_account_id,kind,detail,reason,created_at').order('created_at', { ascending: false }).limit(500),
  ])
  const history = new Map<string, BankEvent[]>()
  for (const ev of (events ?? []) as BankEvent[]) history.set(ev.bank_account_id, [...(history.get(ev.bank_account_id) ?? []), ev])
  const change = (d: unknown, show: (v: string) => string) => {
    const c = d as { from?: string; to?: string } | undefined
    return c && c.from !== c.to ? `${show(String(c.from))} → ${show(String(c.to))}` : null
  }
  const describe = (ev: BankEvent) => ev.kind === 'created'
    ? `com saldo inicial ${brl(String(ev.detail.opening_balance))} em ${dayLabel(String(ev.detail.opening_on))}`
    : ev.kind === 'opening_changed' ? [change(ev.detail.opening_balance, brl), change(ev.detail.opening_on, dayLabel)].filter(Boolean).join(' · ') : ''
  const bal = new Map(((balances ?? []) as { bank_account_id: string; balance: string; pending_lines: number }[]).map(b => [b.bank_account_id, b]))
  const form = (b?: Bank) => (
    <form action={saveBankAccount} className="grid gap-3 sm:grid-cols-4">
      {b && <input type="hidden" name="id" value={b.id} />}
      <label className={label}>Banco<select name="bank_name" defaultValue={b?.bank_name ?? FIN_BANKS[0]} className="field mt-1.5">{FIN_BANKS.map(x => <option key={x} value={x}>{x}</option>)}</select></label>
      <label className={label}>Nome da conta<input name="label" required minLength={2} maxLength={60} defaultValue={b?.label ?? ''} placeholder="Ex.: C6 Smart" className="field mt-1.5" /></label>
      <label className={label}>Agência<input name="agency" maxLength={10} defaultValue={b?.agency ?? ''} className="field mt-1.5" /></label>
      <label className={label}>Conta<input name="account_number" maxLength={20} defaultValue={b?.account_number ?? ''} className="field mt-1.5" /></label>
      <label className={label}>Saldo inicial (R$)<input name="opening_balance" inputMode="decimal" defaultValue={b ? moneyText(b.opening_balance) : '0,00'} className="field mt-1.5" /></label>
      <label className={label}>Data do saldo inicial<input type="date" name="opening_on" defaultValue={b?.opening_on ?? ''} className="field mt-1.5" /></label>
      {b && <label className={label}>Situação<select name="is_active" defaultValue={b.is_active ? 'true' : 'false'} className="field mt-1.5"><option value="true">Ativa</option><option value="false">Desativada</option></select></label>}
      {b && <label className={`${label} sm:col-span-3`}>Motivo <span className="font-normal text-muted">(obrigatório só quando muda o saldo inicial ou a data dele)</span><input name="reason" maxLength={200} className="field mt-1.5" /></label>}
      <div className="flex items-end justify-end"><SubmitButton className="h-10 rounded-none bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">{b ? 'Salvar' : 'Cadastrar conta'}</SubmitButton></div>
    </form>
  )

  return (
    <section>
      <PageHeader title="Contas bancárias" description="As contas da empresa. O saldo é o saldo inicial mais tudo o que foi baixado na conta desde a data dele." />
      <FinanceTabs current="/app/financeiro/empresa/contas" />
      {edit && <Card className="mb-4"><CardHeader title="Nova conta" /><div className="px-5 pb-5">{form()}</div></Card>}
      {!(banks ?? []).length ? <Card className="p-5 text-sm text-muted">Nenhuma conta cadastrada.</Card> : (
        <div className="grid gap-4">
          {((banks ?? []) as Bank[]).map(b => {
            const x = bal.get(b.id)
            return (
              <Card key={b.id}>
                <CardHeader title={<span className="flex flex-wrap items-center gap-2">{b.label} <span className="text-sm font-normal text-muted">{b.bank_name}{b.agency ? ` · ag. ${b.agency}` : ''}{b.account_number ? ` · c/c ${b.account_number}` : ''}</span>{!b.is_active && <Badge tone="neutral">Desativada</Badge>}</span>}
                  action={<span className="text-right"><span className="num block text-lg font-semibold text-ink">{brl(x?.balance ?? b.opening_balance)}</span><span className="text-xs text-muted">saldo inicial {brl(b.opening_balance)} em {dayLabel(b.opening_on)}{x?.pending_lines ? ` · ${x.pending_lines} linha(s) do extrato a conciliar` : ''}</span></span>} />
                <div className="px-5 pb-3"><Link href={`/app/financeiro/empresa/contas/${b.id}`} className="text-sm font-medium text-brand hover:underline">Ver movimentações</Link></div>
                {edit && <details className="px-5 pb-3"><summary className="cursor-pointer text-sm text-muted underline">Editar</summary><div className="mt-3">{form(b)}</div></details>}
                <details className="px-5 pb-5"><summary className="cursor-pointer text-sm text-muted underline">Histórico da conta</summary>
                  <ul className="mt-2 space-y-1 text-sm text-ink-soft">
                    {(history.get(b.id) ?? []).map(ev => (
                      <li key={ev.id}><span className="num text-xs text-muted">{new Date(ev.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' })}</span>{' · '}
                        <span className="font-medium text-ink">{EVENT_LABEL[ev.kind] ?? ev.kind}</span>{describe(ev) ? ` ${describe(ev)}` : ''}{ev.reason ? ` · Motivo: ${ev.reason}` : ''}</li>
                    ))}
                    {!(history.get(b.id) ?? []).length && <li className="text-muted">Sem registros.</li>}
                  </ul>
                </details>
              </Card>
            )
          })}
        </div>
      )}
    </section>
  )
}
