import { Badge, Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can, type Access } from '@/lib/access'
import { add, fromDecimalString, mul, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { decimalBr } from '@/lib/commission/tableValues'
import { brlText } from '@/lib/receipts/format'
import { calculateCommission } from './commission-actions'
import { setPayoutOverride } from './contract-actions'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type Line = { component_key: string; part: string; multiplier: number; line_kind: string; amount: string }
type Payout = { component_key: string; received: string; rule_amount: string; base_amount: string | null; value_kind: string | null; value: string | null; payable: string; overridden: boolean; locked: boolean }

const COMPONENT_LABEL: Record<string, string> = { upfront: 'À vista', deferred: 'Diferido', bonus_1: 'Bônus 1', bonus_2: 'Bônus 2', bonus_3: 'Bônus 3', plastic: 'Plástico', insurance_fixed: 'Seguro' }
const MODE_LABEL: Record<string, string> = { group_values: 'Tabela e grupo do vendedor', cascade: 'Cascata (antigo)', group_table: 'Tabela por grupo (antigo)' }
const ZERO = fromDecimalString('0')
const R = (v: string | number | null | undefined) => fromDecimalString(String(v ?? '0'))
const money = (v: Rational) => brlText(toDecimalString(v, 2))
const pctBr = (v?: string | null) => decimalBr(String(v ?? '0')) || '0'
const lbl = 'text-[13px] font-medium text-ink-soft'

type Calc = { id: string; mode?: string; tax_rate_pct?: string; tax_exempt?: boolean; ir_withheld_pct?: string | null; pay_deferred?: boolean; installments?: number | null; calculated_at: string }
type Mine = { calculated: boolean; calculated_at?: string; mine?: boolean; payable?: { component_key: string; amount: string }[] }

// The contract commission (parts C1/C2). Finance sees, per commission type, what the company receives, tax, IR, the
// seller by the rule and what is payable (the owner's or a manager's change, with reason), supervisor, manager and the
// margin. Anyone else sees only what they receive, on their own contracts (ADR-0031).
export async function CommissionCard({ supabase, access, proposalId, closed, canOverride }: { supabase: Supa; access: Access | null; proposalId: string; closed: boolean; canOverride: boolean }) {
  const finance = can(access, 'financeiro.view')
  let calc: Calc | null = null
  let lines: Line[] = []
  let payouts: Payout[] = []
  let mine: Mine | null = null
  if (finance) {
    const { data } = await supabase.from('proposal_commission_calcs').select('id,mode,tax_rate_pct,tax_exempt,ir_withheld_pct,pay_deferred,installments,calculated_at')
      .eq('proposal_id', proposalId).eq('status', 'active').maybeSingle()
    if (data) {
      calc = data
      const [{ data: lineRows }, { data: payoutRows }] = await Promise.all([
        supabase.from('proposal_commission_lines').select('component_key,part,multiplier,line_kind,amount').eq('calc_id', data.id),
        supabase.rpc('contract_payout', { p_proposal: proposalId }),
      ])
      lines = (lineRows ?? []) as Line[]
      const order = Object.keys(COMPONENT_LABEL)
      payouts = ((payoutRows ?? []) as Payout[]).sort((a, b) => order.indexOf(a.component_key) - order.indexOf(b.component_key))
    }
  } else {
    const { data } = await supabase.rpc('proposal_commission_mine', { p_proposal: proposalId })
    mine = data as Mine | null
    if (mine?.calculated && mine.calculated_at) calc = { id: '', calculated_at: mine.calculated_at }
  }
  const received = payouts.some(p => p.locked)
  const canCalc = (can(access, 'propostas.edit') || can(access, 'financeiro.edit')) && !closed && !received

  // What the paying source actually paid for this contract (confirmed reports), for finance.
  const { data: receiptRows } = finance ? await supabase.from('commission_receipts').select('entry_kind,component_key,amount,reconciliation').eq('proposal_id', proposalId) : { data: [] }
  const receipts = (receiptRows ?? []) as { entry_kind: string; component_key: string | null; amount: string; reconciliation: string }[]
  const sumOf = (f: (r: (typeof receipts)[number]) => boolean) => receipts.filter(f).reduce((acc, r) => add(acc, R(r.amount)), ZERO)
  const recUpfront = sumOf(r => r.entry_kind === 'receipt' && r.component_key === 'upfront')
  const recDeferred = sumOf(r => r.entry_kind === 'receipt' && r.component_key === 'deferred')
  const recChargeback = sumOf(r => r.entry_kind === 'chargeback')

  const total = (component: string, kind: string) => lines.filter(l => l.component_key === component && l.line_kind === kind).reduce((acc, l) => add(acc, mul(R(l.amount), R(l.multiplier))), ZERO)
  const rows = payouts.map(p => {
    const rule = R(p.rule_amount), payable = R(p.payable)
    const margin = add(total(p.component_key, 'company'), sub(rule, payable))
    return { p, received: R(p.received), tax: total(p.component_key, 'tax'), ir: total(p.component_key, 'ir_withheld'), supervisor: total(p.component_key, 'supervisor'),
      manager: total(p.component_key, 'manager'), rule, payable, gain: sub(rule, payable), margin }
  })
  const sumRows = (k: 'received' | 'tax' | 'ir' | 'supervisor' | 'manager' | 'rule' | 'payable' | 'gain' | 'margin') => rows.reduce((acc, r) => add(acc, r[k]), ZERO)
  const nonZero = (v: Rational) => toDecimalString(v, 2) !== '0.00'
  const showIr = rows.some(r => nonZero(r.ir)), showSup = rows.some(r => nonZero(r.supervisor)), showMgr = rows.some(r => nonZero(r.manager))
  const anyOverride = rows.some(r => r.p.overridden)
  const th = 'px-3 py-2 text-right font-medium'
  const td = 'num whitespace-nowrap px-3 py-2 text-right'

  return (
    <Card id="comissao" className="mt-4">
      <CardHeader
        title={<span className="flex flex-wrap items-center gap-2">Comissão {calc?.mode && <Badge tone="brand">{MODE_LABEL[calc.mode] ?? calc.mode}</Badge>}{finance && calc?.tax_exempt && <Badge tone="received">Sem imposto</Badge>}{anyOverride && <Badge tone="pending">Repasse alterado</Badge>}</span>}
        action={canCalc ? (
          <form action={calculateCommission}>
            <input type="hidden" name="proposal_id" value={proposalId} />
            <button className="h-9 rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted">{calc ? 'Recalcular' : 'Calcular comissão'}</button>
          </form>
        ) : undefined}
      />
      <div className="p-5 pt-3 text-sm">
        {!calc ? (
          <p className="text-muted">Comissão ainda não calculada. O cálculo usa a linha da tabela (o que a empresa recebe, o imposto e o valor de cada grupo), a regra do grupo do vendedor, o IR retido pelo banco e a hierarquia do vendedor.</p>
        ) : !finance ? (
          mine?.mine ? (
            <table className="w-full text-left text-[13px]">
              <thead className="text-xs text-muted"><tr><th className="py-2 pr-3 font-medium">Tipo de comissão</th><th className={th}>Você recebe</th></tr></thead>
              <tbody>
                {(mine.payable ?? []).map(x => <tr key={x.component_key} className="border-t border-line"><td className="py-2 pr-3 text-ink">{COMPONENT_LABEL[x.component_key] ?? x.component_key}</td><td className={td}>{brlText(x.amount)}</td></tr>)}
                <tr className="border-t-2 border-line-strong font-semibold"><td className="py-2 pr-3 text-ink">Total do contrato</td><td className={td}>{money((mine.payable ?? []).reduce((a, x) => add(a, R(x.amount)), ZERO))}</td></tr>
              </tbody>
              <caption className="caption-bottom pt-2 text-left text-xs text-muted">Você vê apenas a sua parte (Vendedor). O restante é visível para o financeiro.</caption>
            </table>
          ) : <p className="text-muted">Os valores desta comissão são visíveis para o vendedor do contrato e para o financeiro.</p>
        ) : (
          <>
            <p className="mb-3 text-xs text-muted">Calculada em {new Date(calc.calculated_at).toLocaleString('pt-BR')} · imposto {calc.tax_exempt ? 'não paga' : `${pctBr(calc.tax_rate_pct)}%`}{calc.ir_withheld_pct && Number(calc.ir_withheld_pct) ? ` · IR retido ${pctBr(calc.ir_withheld_pct)}%` : ''}{calc.installments ? ` · diferido em ${calc.installments} parcelas` : ''}</p>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[760px] text-left text-[13px]">
                <thead className="text-xs text-muted">
                  <tr><th className="py-2 pr-3 font-medium">Tipo</th><th className={th}>Empresa recebe</th><th className={th}>Imposto</th>{showIr && <th className={th}>IR retido</th>}
                    {showSup && <th className={th}>Supervisor</th>}{showMgr && <th className={th}>Gerente</th>}<th className={th}>Vendedor pela regra</th><th className={th}>Vendedor a pagar</th><th className={th}>Margem</th></tr>
                </thead>
                <tbody>
                  {rows.map(r => (
                    <tr key={r.p.component_key} className="border-t border-line">
                      <td className="py-2 pr-3 text-ink">{COMPONENT_LABEL[r.p.component_key] ?? r.p.component_key}</td>
                      <td className={td}>{money(r.received)}</td><td className={td}>{money(r.tax)}</td>{showIr && <td className={td}>{money(r.ir)}</td>}
                      {showSup && <td className={td}>{money(r.supervisor)}</td>}{showMgr && <td className={td}>{money(r.manager)}</td>}
                      <td className={`${td} ${r.p.overridden ? 'text-muted line-through' : ''}`}>{money(r.rule)}</td>
                      <td className={`${td} font-medium text-ink`}>{money(r.payable)}{r.p.overridden && <span className="block text-[11px] font-normal text-muted">{r.p.value_kind === 'fixed_brl' ? 'valor fixo' : `${pctBr(r.p.value)}% da base`}</span>}</td>
                      <td className={`${td} ${toDecimalString(r.margin, 2).startsWith('-') ? 'text-[#B91C1C]' : 'text-ink'}`}>{money(r.margin)}</td>
                    </tr>
                  ))}
                  <tr className="border-t-2 border-line-strong font-semibold">
                    <td className="py-2 pr-3 text-ink">Total do contrato</td>
                    <td className={td}>{money(sumRows('received'))}</td><td className={td}>{money(sumRows('tax'))}</td>{showIr && <td className={td}>{money(sumRows('ir'))}</td>}
                    {showSup && <td className={td}>{money(sumRows('supervisor'))}</td>}{showMgr && <td className={td}>{money(sumRows('manager'))}</td>}
                    <td className={td}>{money(sumRows('rule'))}</td><td className={td}>{money(sumRows('payable'))}</td><td className={td}>{money(sumRows('margin'))}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            {anyOverride && <p className="mt-2 text-[13px] text-ink-soft">Ganho da empresa com a alteração do repasse: <strong className="text-ink">{money(sumRows('gain'))}</strong></p>}

            {canOverride && !received && rows.length > 0 && (
              <div className="mt-4 grid gap-2 border-t border-line pt-4">
                {rows.map(r => (
                  <details key={r.p.component_key} className="rounded-[12px] border border-line px-4 py-3">
                    <summary className="cursor-pointer text-sm font-medium text-ink">Alterar repasse do vendedor — {COMPONENT_LABEL[r.p.component_key] ?? r.p.component_key}</summary>
                    <form action={setPayoutOverride} className="mt-3 grid gap-3 sm:grid-cols-[160px_160px_1fr_auto] sm:items-end">
                      <input type="hidden" name="proposal_id" value={proposalId} /><input type="hidden" name="component" value={r.p.component_key} />
                      <label className={lbl}>Tipo<select name="kind" defaultValue={r.p.value_kind ?? 'percentage'} className="field mt-1.5"><option value="percentage">% da base</option><option value="fixed_brl">Valor fixo (R$)</option></select></label>
                      <label className={lbl}>Valor<input name="value" required inputMode="decimal" placeholder="4 ou 800,00" aria-label={`Repasse ${COMPONENT_LABEL[r.p.component_key] ?? r.p.component_key}`} className="field mt-1.5" /></label>
                      <label className={lbl}>Motivo<input name="reason" required minLength={3} maxLength={500} placeholder="Obrigatório" aria-label={`Motivo ${COMPONENT_LABEL[r.p.component_key] ?? r.p.component_key}`} className="field mt-1.5" /></label>
                      <SubmitButton className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Salvar repasse</SubmitButton>
                    </form>
                    {r.p.overridden && (
                      <form action={setPayoutOverride} className="mt-3 flex flex-wrap items-end gap-2 border-t border-line pt-3">
                        <input type="hidden" name="proposal_id" value={proposalId} /><input type="hidden" name="component" value={r.p.component_key} /><input type="hidden" name="clear" value="1" />
                        <label className={`${lbl} flex-1`}>Motivo para voltar à regra<input name="reason" required minLength={3} maxLength={500} className="field mt-1.5" /></label>
                        <SubmitButton className="h-10 rounded-[10px] border border-line-strong bg-surface px-4 text-sm text-ink hover:bg-surface-muted" pendingText="...">Voltar à regra</SubmitButton>
                      </form>
                    )}
                  </details>
                ))}
              </div>
            )}

            <p className="mt-4 border-t border-line pt-3 text-[13px] text-ink-soft">
              Recebido do banco: à vista {money(recUpfront)} · diferido {money(recDeferred)} · estornos {money(recChargeback)} · líquido <span className="font-semibold text-ink">{money(sub(add(recUpfront, recDeferred), recChargeback))}</span>
              {receipts.some(r => r.reconciliation === 'divergent') && <span className="ml-1 text-[#92400E]">(há recebimento divergente; veja a conciliação)</span>}
            </p>
          </>
        )}
      </div>
    </Card>
  )
}
