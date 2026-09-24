import { Badge, Card, CardHeader } from '@/components/ui'
import { can, type Access } from '@/lib/access'
import { add, fromDecimalString, mul, toDecimalString, type Rational } from '@/lib/commission/money'
import { calculateCommission } from './commission-actions'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type Line = { component_key: string; part: string; multiplier: number; line_kind: string; amount: string }

const KINDS = ['received', 'tax', 'manager', 'supervisor', 'originator', 'company'] as const
const KIND_LABEL: Record<string, string> = { received: 'Recebido do banco', tax: 'Imposto', manager: 'Gerente', supervisor: 'Supervisor', originator: 'Vendedor', company: 'Empresa' }
const COMPONENT_LABEL: Record<string, string> = { upfront: 'À vista', deferred: 'Diferido', bonus_1: 'Bônus 1', bonus_2: 'Bônus 2', bonus_3: 'Bônus 3', plastic: 'Plástico', insurance_fixed: 'Seguro' }
const brl = (v: string) => Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
const ZERO = fromDecimalString('0')

// Frozen commission of the proposal. Totals are exact sums (amount × installments) of the stored lines.
export async function CommissionCard({ supabase, access, proposalId, closed }: { supabase: Supa; access: Access | null; proposalId: string; closed: boolean }) {
  const { data: calc } = await supabase.from('proposal_commission_calcs')
    .select('id,mode,tax_rate_pct,tax_exempt,pay_deferred,installments,calculated_at')
    .eq('proposal_id', proposalId).eq('status', 'active').maybeSingle()
  const { data: lineRows } = calc ? await supabase.from('proposal_commission_lines').select('component_key,part,multiplier,line_kind,amount').eq('calc_id', calc.id) : { data: [] as Line[] }
  const lines = (lineRows ?? []) as Line[]
  const finance = can(access, 'financeiro.view')
  const canCalc = (can(access, 'propostas.edit') || can(access, 'financeiro.edit')) && !(closed && calc)

  const totals = new Map<string, Rational>()
  for (const l of lines) totals.set(l.line_kind, add(totals.get(l.line_kind) ?? ZERO, mul(fromDecimalString(String(l.amount)), fromDecimalString(String(l.multiplier)))))
  const components = [...new Set(lines.map(l => l.component_key))]
  const visibleKinds = KINDS.filter(k => finance || k === 'originator')
  const cell = (component: string, part: string, kind: string) => lines.find(l => l.component_key === component && l.part === part && l.line_kind === kind)?.amount

  return (
    <Card className="mt-6">
      <CardHeader
        title={<span className="flex items-center gap-2">Comissão {calc && <Badge tone="brand">{calc.mode === 'cascade' ? 'Cascata' : 'Tabela por grupo'}</Badge>}{calc?.tax_exempt && <Badge tone="received">Fonte isenta</Badge>}</span>}
        action={canCalc ? (
          <form action={calculateCommission}>
            <input type="hidden" name="proposal_id" value={proposalId} />
            <button className="h-9 rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted">{calc ? 'Recalcular' : 'Calcular comissão'}</button>
          </form>
        ) : undefined}
      />
      <div className="p-5 pt-3 text-sm">
        {!calc ? (
          <p className="text-muted">Comissão ainda não calculada. O cálculo usa a condição da tabela, as regras de comissão da empresa e a hierarquia do vendedor, e fica congelado na proposta.</p>
        ) : (
          <>
            <p className="mb-3 text-xs text-muted">Calculada em {new Date(calc.calculated_at).toLocaleString('pt-BR')} · imposto {calc.tax_exempt ? 'isento' : `${String(calc.tax_rate_pct).replace(/0+$/, '').replace(/\.$/, '').replace('.', ',')}%`} · diferido {calc.pay_deferred ? 'repassado à equipe' : 'fica com a empresa'}</p>
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
                    {visibleKinds.map(k => <td key={k} className="num px-3 py-2 text-right text-ink">{brl(toDecimalString(totals.get(k) ?? ZERO, 2))}</td>)}
                  </tr>
                </tbody>
              </table>
            </div>
            {!finance && <p className="mt-2 text-xs text-muted">Você vê apenas a sua parte (Vendedor). O restante é visível para o financeiro.</p>}
          </>
        )}
      </div>
    </Card>
  )
}
