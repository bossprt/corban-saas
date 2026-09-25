import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { brlText } from '@/lib/receipts/format'
import { dateBr, ENTRY_KIND_LABEL, ENTRY_STATUS_LABEL, MODEL_LABEL } from '@/lib/payout/format'
import { addEntry, decideEntry, requestWithdrawal, setAccountModel } from '../actions'
import { PayoutRows, type PayoutRow } from '../PayoutRows'

type Entry = { id: string; kind: string; amount: string; effective_on: string; description: string | null; status: string; proposal_id: string | null; beneficiary_role: string | null; created_at: string; decision_note: string | null; statement_id: string | null }
type Summary = { account_id: string; holder_name: string; model: string; balance: string; available: string }
const ROLE_LABEL: Record<string, string> = { originator: 'vendedor', supervisor: 'supervisor', manager: 'gerente' }
const label = 'text-[13px] font-medium text-ink-soft'
const todayIso = () => new Date().toISOString().slice(0, 10)

// One person's current account: every movement, statements and withdrawals, and the forms finance or the person may use.
export default async function PayoutAccountPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, organization, access } = await requireAppContext()
  const { data: summaryRows } = await supabase.rpc('payout_account_summaries', { p_org: organization.id })
  const account = ((summaryRows ?? []) as Summary[]).find(s => s.account_id === id)
  if (!account) notFound()
  const [{ data: entryRows }, { data: payoutRows }] = await Promise.all([
    supabase.from('payout_entries').select('id,kind,amount,effective_on,description,status,proposal_id,beneficiary_role,created_at,decision_note,statement_id').eq('account_id', id).order('effective_on', { ascending: false }).order('created_at', { ascending: false }).limit(1000),
    supabase.from('payouts').select('id,account_id,kind,period_start,period_end,carry_in,period_net,debt_deduction,amount,carry_out,status,requested_at,paid_on,payment_reference,note').eq('account_id', id).order('requested_at', { ascending: false }).limit(200),
  ])
  const entries = (entryRows ?? []) as Entry[]
  const finance = can(access, 'repasse.view')
  const canCreate = can(access, 'repasse.create') || can(access, 'repasse.edit')
  const canApprove = can(access, 'repasse.approve')
  const back = `/app/repasse/${id}`

  return (
    <section>
      <PageHeader title={account.holder_name} description={<>Modelo: {MODEL_LABEL[account.model]}. {finance && <Link href="/app/repasse" className="text-brand hover:underline">Voltar ao repasse</Link>}</>} />

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <div className="rounded-[14px] border border-line bg-surface px-5 py-4"><div className="text-[13px] text-muted">Saldo da conta</div><div className={`num mt-1 text-2xl font-semibold ${String(account.balance).startsWith('-') ? 'text-[#991B1B]' : 'text-ink'}`}>{brlText(account.balance)}</div></div>
        {account.model === 'account' && <div className="rounded-[14px] border border-line bg-surface px-5 py-4"><div className="text-[13px] text-muted">Disponível para saque hoje</div><div className="num mt-1 text-2xl font-semibold text-ink">{brlText(account.available)}</div></div>}
      </div>

      <div className="mb-4 grid gap-4 lg:grid-cols-2">
        {account.model === 'account' && (
          <Card className="p-5">
            <h2 className="mb-3 text-sm font-semibold text-ink">Pedir saque</h2>
            <form action={requestWithdrawal} className="flex flex-wrap items-end gap-2">
              <input type="hidden" name="account_id" value={id} />
              <label className={label}>Valor (R$)<input name="amount" inputMode="decimal" required placeholder="0,00" className="field mt-1.5 w-40" /></label>
              <label className={label}>Observação<input name="note" className="field mt-1.5 w-56" /></label>
              <button className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Pedir saque</button>
            </form>
          </Card>
        )}
        {canCreate && (
          <Card className="p-5">
            <h2 className="mb-3 text-sm font-semibold text-ink">Lançamento avulso <span className="font-normal text-muted">(aguarda aprovação de outra pessoa)</span></h2>
            <form action={addEntry} className="grid gap-3 sm:grid-cols-3">
              <input type="hidden" name="account_id" value={id} />
              <label className={label}>Tipo<select name="kind" className="field mt-1.5"><option value="advance">Vale (débito)</option><option value="bonus">Bônus (crédito)</option><option value="discount">Desconto (débito)</option><option value="adjustment">Ajuste</option></select></label>
              <label className={label}>Valor (R$)<input name="amount" inputMode="decimal" required placeholder="0,00" className="field mt-1.5" /></label>
              <label className={label}>Ajuste é<select name="direction" className="field mt-1.5"><option value="credit">crédito</option><option value="debit">débito</option></select></label>
              <label className={`${label} sm:col-span-2`}>Descrição<input name="description" required minLength={3} maxLength={180} className="field mt-1.5" /></label>
              <label className={label}>Parcelas <span className="font-normal text-muted">vale ou desconto</span><input name="installments" type="number" min={1} max={48} defaultValue={1} className="field mt-1.5" /></label>
              <label className={label}>A partir de<input name="effective_on" type="date" defaultValue={todayIso()} className="field mt-1.5" /></label>
              <div className="flex items-end justify-end sm:col-span-2"><button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted">Lançar</button></div>
            </form>
          </Card>
        )}
        {can(access, 'repasse.edit') && (
          <Card className="p-5">
            <h2 className="mb-3 text-sm font-semibold text-ink">Modelo de repasse desta pessoa</h2>
            <form action={setAccountModel} className="flex flex-wrap items-end gap-2">
              <input type="hidden" name="account_id" value={id} />
              <select name="model" defaultValue="" className="field w-64"><option value="">Padrão da empresa</option><option value="closing">Fechamento periódico</option><option value="account">Conta interna (saque)</option></select>
              <button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted">Salvar</button>
            </form>
            <p className="mt-2 text-xs text-muted">Ao passar para fechamento, o saldo atual vira o saldo de abertura: nada é pago duas vezes.</p>
          </Card>
        )}
      </div>

      <Card className="mb-4 overflow-hidden">
        <CardHeader title="Repasses" />
        <PayoutRows rows={(payoutRows ?? []) as PayoutRow[]} back={back} canApprove={canApprove} canPay={canCreate || canApprove} />
      </Card>

      <Card className="overflow-hidden">
        <CardHeader title="Extrato" />
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-3 py-2">Data</th><th className="px-3 py-2">Lançamento</th><th className="px-3 py-2">Descrição</th><th className="px-3 py-2 text-right">Valor</th><th className="px-3 py-2">Situação</th></tr></thead>
            <tbody>
              {entries.map(e => (
                <tr key={e.id} className="border-t border-line align-top">
                  <td className="num px-3 py-2 text-muted">{dateBr(e.effective_on)}</td>
                  <td className="px-3 py-2">{ENTRY_KIND_LABEL[e.kind]}{e.beneficiary_role && <span className="ml-1 text-xs text-muted">({ROLE_LABEL[e.beneficiary_role]})</span>}</td>
                  <td className="px-3 py-2 text-ink-soft">{e.proposal_id ? <Link href={`/app/propostas/${e.proposal_id}`} className="hover:underline">{e.description}</Link> : e.description}{e.decision_note && <div className="text-xs text-muted">{e.decision_note}</div>}</td>
                  <td className={`num px-3 py-2 text-right ${String(e.amount).startsWith('-') ? 'text-[#991B1B]' : 'text-ink'}`}>{brlText(e.amount)}</td>
                  <td className="px-3 py-2">
                    <Badge tone={e.status === 'approved' ? 'received' : e.status === 'pending' ? 'pending' : 'neutral'}>{ENTRY_STATUS_LABEL[e.status]}</Badge>
                    {e.status === 'pending' && canApprove && (
                      <form action={decideEntry} className="mt-1 inline-flex gap-1"><input type="hidden" name="entry_id" value={e.id} /><input type="hidden" name="back" value={back} /><input type="hidden" name="decision" value="approve" />
                        <button className="h-7 rounded-md bg-brand px-2 text-xs font-semibold text-white hover:bg-brand-strong">Aprovar</button></form>
                    )}
                  </td>
                </tr>
              ))}
              {!entries.length && <tr><td colSpan={5} className="px-3 py-8 text-center text-muted">Nenhum lançamento.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
