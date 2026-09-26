import { Badge, Card, CardHeader } from '@/components/ui'
import { can, type Access } from '@/lib/access'
import { add, fromDecimalString, mul, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { brlText } from '@/lib/receipts/format'
import { calculateCommission } from './commission-actions'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type Line = { component_key: string; part: string; multiplier: number; line_kind: string; amount: string }

const KINDS = ['received', 'tax', 'ir_withheld', 'manager', 'supervisor', 'originator', 'company'] as const
const KIND_LABEL: Record<string, string> = { received: 'Empresa recebe', tax: 'Imposto', ir_withheld: 'IR retido', manager: 'Gerente', supervisor: 'Supervisor', originator: 'Vendedor', company: 'Margem' }
const MODE_LABEL: Record<string, string> = { group_values: 'Tabela e grupo do vendedor', cascade: 'Cascata (antigo)', group_table: 'Tabela por grupo (antigo)' }
const pctBr = (v?: string | null) => String(v ?? '0').replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '').replace('.', ',')
const COMPONENT_LABEL: Record<string, string> = { upfront: 'À vista', deferred: 'Diferido', bonus_1: 'Bônus 1', bonus_2: 'Bônus 2', bonus_3: 'Bônus 3', plastic: 'Plástico', insurance_fixed: 'Seguro' }
const brl = (v: string) => brlText(v)
const ZERO = fromDecimalString('0')

type Calc = { mode?: string; tax_rate_pct?: string; tax_exempt?: boolean; ir_withheld_pct?: string | null; pay_deferred?: boolean; installments?: number | null; calculated_at: string }
type Mine = { calculated: boolean; calculated_at?: string; mine?: boolean; lines?: Omit<Line, 'line_kind'>[] }

// Frozen commission of the proposal. Totals are exact sums (amount × installments) of the stored lines.
// Finance reads the whole calculation; anyone else gets only the seller's own share, and only on their own proposals
// (ADR-0031): the header with the company percentages never leaves the database for them.
export async function CommissionCard({ supabase, access, proposalId, closed }: { supabase: Supa; access: Access | null; proposalId: string; closed: boolean }) {
  const finance = can(access, 'financeiro.view')
  let calc: Calc | null = null
  let lines: Line[] = []
  let notMine = false
  if (finance) {
    const { data } = await supabase.from('proposal_commission_calcs')
      .select('id,mode,tax_rate_pct,tax_exempt,ir_withheld_pct,pay_deferred,installments,calculated_at')
      .eq('proposal_id', proposalId).eq('status', 'active').maybeSingle()
    if (data) {
      calc = data
      const { data: lineRows } = await supabase.from('proposal_commission_lines').select('component_key,part,multiplier,line_kind,amount').eq('calc_id', data.id)
      lines = (lineRows ?? []) as Line[]
    }
  } else {
    const { data } = await supabase.rpc('proposal_commission_mine', { p_proposal: proposalId })
    const mine = data as Mine | null
    if (mine?.calculated && mine.calculated_at) {
      calc = { calculated_at: mine.calculated_at }
      notMine = !mine.mine
      lines = (mine.lines ?? []).map(l => ({ ...l, line_kind: 'originator' }))
    }
  }
  // What the paying source actually paid for this contract (confirmed reports), for finance.
  const { data: receiptRows } = finance ? await supabase.from('commission_receipts').select('entry_kind,component_key,amount,reconciliation').eq('proposal_id', proposalId) : { data: [] }
  const receipts = (receiptRows ?? []) as { entry_kind: string; component_key: string | null; amount: string; reconciliation: string }[]
  const sumOf = (f: (r: (typeof receipts)[number]) => boolean) => receipts.filter(f).reduce((acc, r) => add(acc, fromDecimalString(String(r.amount))), ZERO)
  const recUpfront = sumOf(r => r.entry_kind === 'receipt' && r.component_key === 'upfront')
  const recDeferred = sumOf(r => r.entry_kind === 'receipt' && r.component_key === 'deferred')
  const recChargeback = sumOf(r => r.entry_kind === 'chargeback')
  const deferredCount = receipts.filter(r => r.entry_kind === 'receipt' && r.component_key === 'deferred').length
  const canCalc = (can(access, 'propostas.edit') || can(access, 'financeiro.edit')) && !(closed && calc)

  const totals = new Map<string, Rational>()
  for (const l of lines) totals.set(l.line_kind, add(totals.get(l.line_kind) ?? ZERO, mul(fromDecimalString(String(l.amount)), fromDecimalString(String(l.multiplier)))))
  const components = [...new Set(lines.map(l => l.component_key))]
  // Finance sees every party with a value; the company receipt, the seller and the margin always show.
  const visibleKinds = KINDS.filter(k => finance ? ['received', 'originator', 'company'].includes(k) || lines.some(l => l.line_kind === k && Number(l.amount) !== 0) : k === 'originator')
  const cell = (component: string, part: string, kind: string) => lines.find(l => l.component_key === component && l.part === part && l.line_kind === kind)?.amount

  return (
    <Card className="mt-6">
      <CardHeader
        title={<span className="flex items-center gap-2">Comissão {calc?.mode && <Badge tone="brand">{MODE_LABEL[calc.mode] ?? calc.mode}</Badge>}{finance && calc?.tax_exempt && <Badge tone="received">Sem imposto</Badge>}</span>}
        action={canCalc ? (
          <form action={calculateCommission}>
            <input type="hidden" name="proposal_id" value={proposalId} />
            <button className="h-9 rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted">{calc ? 'Recalcular' : 'Calcular comissão'}</button>
          </form>
        ) : undefined}
      />
      <div className="p-5 pt-3 text-sm">
        {!calc ? (
          <p className="text-muted">Comissão ainda não calculada. O cálculo usa a linha da tabela (o que a empresa recebe, o imposto e o valor de cada grupo), a regra do grupo do vendedor, o IR retido pelo banco e a hierarquia do vendedor. Fica guardado no contrato.</p>
        ) : (
          <>
            <p className="mb-3 text-xs text-muted">Calculada em {new Date(calc.calculated_at).toLocaleString('pt-BR')}{finance && <> · imposto {calc.tax_exempt ? 'não paga' : `${pctBr(calc.tax_rate_pct)}%`}{calc.ir_withheld_pct && Number(calc.ir_withheld_pct) ? ` · IR retido ${pctBr(calc.ir_withheld_pct)}%` : ''} · diferido {calc.pay_deferred ? 'repassado à equipe' : 'fica com a empresa'}</>}</p>
            {notMine ? <p className="text-muted">Os valores desta comissão são visíveis para o vendedor da proposta e para o financeiro.</p> : <>
            <div className="overflow-x-auto">
              <table className="w-full text-left text-[13px]">
                <thead className="text-xs text-muted"><tr><th className="py-2 pr-3 font-medium">Componente</th>{visibleKinds.map(k => <th key={k} className="px-3 py-2 text-right font-medium">{KIND_LABEL[k]}</th>)}</tr></thead>
                <tbody>
                  {components.flatMap(c => {
                    const parts = c === 'deferred' ? ['deferred_standard', 'deferred_last'] : ['upfront']
                    return parts.map(part => {
                      const mult = lines.find(l => l.component_key === c && l.part === part)?.multiplier ?? 1
                      const name = part === 'deferred_standard' ? `${COMPONENT_LABEL[c] ?? c} · parcela (×${mult})` : part === 'deferred_last' ? `${COMPONENT_LABEL[c] ?? c} · última parcela` : (COMPONENT_LABEL[c] ?? c)
                      return (
                        <tr key={`${c}-${part}`} className="border-t border-line">
                          <td className="py-2 pr-3 text-ink">{name}</td>
                          {visibleKinds.map(k => <td key={k} className="num px-3 py-2 text-right text-ink-soft">{cell(c, part, k) ? brl(String(cell(c, part, k))) : '—'}</td>)}
                        </tr>
                      )
                    })
                  })}
                  <tr className="border-t-2 border-line-strong font-semibold">
                    <td className="py-2 pr-3 text-ink">Total do contrato</td>
                    {visibleKinds.map(k => { const v = toDecimalString(totals.get(k) ?? ZERO, 2); return <td key={k} className={`num px-3 py-2 text-right ${k === 'company' && v.startsWith('-') ? 'text-[#B91C1C]' : 'text-ink'}`}>{brl(v)}</td> })}
                  </tr>
                </tbody>
              </table>
            </div>
            {!finance && <p className="mt-2 text-xs text-muted">Você vê apenas a sua parte (Vendedor). O restante é visível para o financeiro.</p>}
            </>}
            {finance && (
              <p className="mt-3 border-t border-line pt-3 text-[13px] text-ink-soft">
                Recebido do banco: à vista {brl(toDecimalString(recUpfront, 2))} · diferido {brl(toDecimalString(recDeferred, 2))} ({deferredCount}{calc.installments ? ` de ${calc.installments}` : ''} parcelas) · estornos {brl(toDecimalString(recChargeback, 2))} · líquido <span className="font-semibold text-ink">{brl(toDecimalString(sub(add(recUpfront, recDeferred), recChargeback), 2))}</span>
                {receipts.some(r => r.reconciliation === 'divergent') && <span className="ml-1 text-[#92400E]">(há recebimento divergente; veja a conciliação)</span>}
              </p>
            )}
          </>
        )}
      </div>
    </Card>
  )
}
