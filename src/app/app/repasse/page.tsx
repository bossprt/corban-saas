import Link from 'next/link'
import { redirect } from 'next/navigation'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { payToText } from '@/lib/sellers'
import { memberEmails } from '@/lib/team.server'
import { brlText } from '@/lib/receipts/format'
import { add, fromDecimalString, toDecimalString, type Rational } from '@/lib/commission/money'
import { dateBr, ENTRY_KIND_LABEL, MODEL_LABEL } from '@/lib/payout/format'
import { closePeriod, decideEntry, openAccount } from './actions'
import { PayoutRows, type PayoutRow } from './PayoutRows'

type Summary = { account_id: string; holder_name: string; holder_kind: string; model: string; balance: string; available: string; pending_entries: number; open_payouts: number }
type Pending = { id: string; account_id: string; kind: string; amount: string; effective_on: string; description: string | null; entry_group: string | null; created_at: string }
const todayIso = () => new Date().toISOString().slice(0, 10)

// Payout home. Finance sees every account, the approvals and the period closing; a person goes to their own account.
export default async function PayoutPage() {
  const { supabase, organization, access, membership } = await requireAppContext()
  const { data: summaryRows } = await supabase.rpc('payout_account_summaries', { p_org: organization.id })
  const summaries = (summaryRows ?? []) as Summary[]
  const finance = can(access, 'repasse.view')
  if (!finance) {
    if (summaries.length === 1) redirect(`/app/repasse/${summaries[0].account_id}`)
    return <section><PageHeader title="Repasse" /><Card className="p-5 text-sm text-ink-soft">Você ainda não tem conta de repasse. Ela abre com o primeiro recebimento conciliado de uma venda sua.</Card></section>
  }
  const canCreate = can(access, 'repasse.create') || can(access, 'repasse.edit')
  const canApprove = can(access, 'repasse.approve')
  const [{ data: pendingRows }, { data: payoutRows }, { data: sellers }, { data: members }] = await Promise.all([
    supabase.from('payout_entries').select('id,account_id,kind,amount,effective_on,description,entry_group,created_at').eq('status', 'pending').order('created_at').limit(300),
    supabase.from('payouts').select('id,account_id,kind,period_start,period_end,carry_in,period_net,debt_deduction,amount,carry_out,status,requested_at,paid_on,payment_reference,note').in('status', ['pending', 'approved']).order('requested_at').limit(300),
    supabase.from('commercial_sellers').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_memberships').select('user_id').eq('status', 'active'),
  ])
  const names = new Map(summaries.map(s => [s.account_id, s.holder_name]))
  // Where to send each seller's money: the primary account of the seller file (bank data: admin, manager, finance).
  const payTo = new Map<string, string>()
  if (can(access, 'financeiro.view') || atLeast(membership.role, 'manager')) {
    const [{ data: accounts }, { data: banks }] = await Promise.all([
      supabase.from('payout_accounts').select('id,seller_id').not('seller_id', 'is', null),
      supabase.from('seller_bank_accounts').select('seller_id,transfer_method,pix_key_type,pix_key,bank_code,bank_name,branch,account_number,account_digit,holder_name,holder_document')
        .eq('is_primary', true).is('removed_at', null),
    ])
    const bySeller = new Map((banks ?? []).map(b => [b.seller_id, payToText(b)]))
    for (const a of accounts ?? []) payTo.set(a.id, bySeller.get(a.seller_id) ?? '')
  }
  const emails = await memberEmails((members ?? []).map(m => m.user_id))
  // One row per manual entry group (installments of the same advance are approved together).
  const groups = new Map<string, Pending & { count: number; total: Rational }>()
  for (const e of (pendingRows ?? []) as Pending[]) {
    const k = e.entry_group ?? e.id
    const g = groups.get(k)
    if (g) { g.count++; g.total = add(g.total, fromDecimalString(String(e.amount))) } else groups.set(k, { ...e, count: 1, total: fromDecimalString(String(e.amount)) })
  }

  return (
    <section>
      <PageHeader title="Repasse" description="Conta corrente de cada pessoa: comissões conciliadas, estornos, vales, bônus e descontos. Todo pagamento é aprovado por outra pessoa." />

      {canCreate && (
        <Card className="mb-4 p-5">
          <div className="flex flex-wrap items-end gap-6">
            <form action={closePeriod} className="flex items-end gap-2">
              <label className="text-[13px] font-medium text-ink-soft">Fechar período até<input type="date" name="period_end" defaultValue={todayIso()} max={todayIso()} className="field mt-1.5" /></label>
              <button className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Fechar período</button>
            </form>
            <form action={openAccount} className="flex items-end gap-2">
              <label className="text-[13px] font-medium text-ink-soft">Abrir conta de
                <select name="payee" required defaultValue="" className="field mt-1.5">
                  <option value="" disabled>Vendedor, corretor ou membro</option>
                  <optgroup label="Vendedores e corretores">{(sellers ?? []).map(s => <option key={s.id} value={`seller:${s.id}`}>{s.name}</option>)}</optgroup>
                  <optgroup label="Equipe">{(members ?? []).map(m => <option key={m.user_id} value={`member:${m.user_id}`}>{emails.get(m.user_id) ?? 'Membro'}</option>)}</optgroup>
                </select>
              </label>
              <button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted">Abrir</button>
            </form>
          </div>
          <p className="mt-3 text-xs text-muted">O fechamento gera o extrato de quem está no modelo de fechamento: lançamentos aprovados até a data. Saldo negativo passa adiante e cada extrato desconta no máximo o limite configurado.</p>
        </Card>
      )}

      <Card className="mb-4 overflow-hidden">
        <CardHeader title="Contas" />
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-4 py-2.5">Pessoa</th><th className="px-4 py-2.5">Modelo</th><th className="px-4 py-2.5 text-right">Saldo</th><th className="px-4 py-2.5 text-right">Disponível hoje</th><th className="px-4 py-2.5">Pendências</th></tr></thead>
          <tbody>
            {summaries.map(s => (
              <tr key={s.account_id} className="border-t border-line hover:bg-surface-muted">
                <td className="px-4 py-2.5"><Link href={`/app/repasse/${s.account_id}`} className="font-medium text-ink hover:underline">{s.holder_name}</Link><span className="ml-2 text-xs text-muted">{s.holder_kind === 'seller' ? 'vendedor' : 'equipe'}</span></td>
                <td className="px-4 py-2.5 text-ink-soft">{MODEL_LABEL[s.model]}</td>
                <td className={`num px-4 py-2.5 text-right ${String(s.balance).startsWith('-') ? 'text-[#991B1B]' : 'text-ink'}`}>{brlText(s.balance)}</td>
                <td className="num px-4 py-2.5 text-right">{s.model === 'account' ? brlText(s.available) : '—'}</td>
                <td className="px-4 py-2.5">{s.pending_entries > 0 && <Badge tone="pending">{s.pending_entries} lançamento(s)</Badge>} {s.open_payouts > 0 && <Badge tone="diverged">{s.open_payouts} repasse(s)</Badge>}</td>
              </tr>
            ))}
            {!summaries.length && <tr><td colSpan={5} className="px-4 py-8 text-center text-muted">Nenhuma conta ainda. As contas abrem com o primeiro recebimento conciliado.</td></tr>}
          </tbody>
        </table>
      </Card>

      <Card className="mb-4 overflow-hidden">
        <CardHeader title="Lançamentos aguardando aprovação" />
        <ul className="text-sm">
          {[...groups.values()].map(g => (
            <li key={g.id} className="flex flex-wrap items-center justify-between gap-3 border-t border-line px-5 py-3 first:border-t-0">
              <span><Link href={`/app/repasse/${g.account_id}`} className="font-medium text-ink hover:underline">{names.get(g.account_id) ?? 'Conta'}</Link> · {ENTRY_KIND_LABEL[g.kind]} · {g.description}
                <span className="num ml-2">{brlText(toDecimalString(g.total, 2))}{g.count > 1 ? ` em ${g.count} parcelas` : ''} · a partir de {dateBr(g.effective_on)}</span></span>
              {canApprove && (
                <span className="flex gap-2">
                  <form action={decideEntry}><input type="hidden" name="entry_id" value={g.id} /><input type="hidden" name="back" value="/app/repasse" /><input type="hidden" name="decision" value="approve" />
                    <button className="h-8 rounded-md bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Aprovar</button></form>
                  <form action={decideEntry} className="flex gap-1"><input type="hidden" name="entry_id" value={g.id} /><input type="hidden" name="back" value="/app/repasse" /><input type="hidden" name="decision" value="reject" />
                    <input name="note" required minLength={3} placeholder="Motivo" className="field h-8 w-28 text-xs" /><button className="h-8 rounded-md px-2 text-xs text-ink-soft hover:bg-surface-muted">Recusar</button></form>
                </span>
              )}
            </li>
          ))}
          {!groups.size && <li className="px-5 py-6 text-center text-muted">Nada aguardando aprovação.</li>}
        </ul>
      </Card>

      <Card className="overflow-hidden">
        <CardHeader title="Repasses em aberto" />
        <PayoutRows rows={(payoutRows ?? []) as PayoutRow[]} names={names} back="/app/repasse" canApprove={canApprove} canPay={canCreate || canApprove} payTo={payTo} />
      </Card>
    </section>
  )
}
