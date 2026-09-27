import { Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, dayLabel, FIN_KIND_LABEL } from '@/lib/finance/labels'
import { FinanceTabs } from '../FinanceTabs'
import { entryFromLine, ignoreLine, matchLine } from '../actions'
import { StatementImportClient } from './StatementImportClient'

type Line = { id: string; bank_account_id: string; posted_on: string; amount: string; memo: string | null }
type Entry = { id: string; direction: string; status: string; description: string; amount: string; due_on: string; settled_on: string | null; bank_account_id: string | null }
type Account = { id: string; code: string; name: string; kind: string; is_group: boolean; is_active: boolean }
const days = (a: string, b: string) => Math.abs(Date.parse(a) - Date.parse(b)) / 86_400_000

// Statement reconciliation: each pending line of the bank statement is matched to the entry with the same direction and
// amount (open, or settled without an account), turned into a new entry (a fee, an unregistered income) or ignored.
export default async function StatementPage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Extrato bancário" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  await supabase.rpc('fin_setup', { p_org: organization.id })
  const edit = can(access, 'financeiro.edit')
  const [{ data: banks }, { data: lines }, { data: candidates }, { data: accounts }, { data: branches }] = await Promise.all([
    supabase.from('fin_bank_accounts').select('id,label').eq('is_active', true).order('label'),
    supabase.from('fin_statement_lines').select('id,bank_account_id,posted_on,amount,memo').eq('status', 'pending').order('posted_on').limit(300),
    supabase.from('fin_entries').select('id,direction,status,description,amount,due_on,settled_on,bank_account_id').or('status.eq.open,and(status.eq.settled,bank_account_id.is.null)').limit(2000),
    supabase.from('fin_chart_accounts').select('id,code,name,kind,is_group,is_active').order('code'),
    supabase.from('organization_branches').select('id,name').eq('is_active', true).order('name'),
  ])
  const bankName = new Map((banks ?? []).map(b => [b.id, b.label]))
  const usable = ((accounts ?? []) as Account[]).filter(a => !a.is_group && a.is_active)
  const pool = (candidates ?? []) as Entry[]
  // Suggestions: same direction and amount, closest date first.
  const suggest = (l: Line) => pool
    .filter(e => (Number(l.amount) > 0) === (e.direction === 'in') && Math.round(Math.abs(Number(l.amount)) * 100) === Math.round(Number(e.amount) * 100))
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
    </section>
  )
}
