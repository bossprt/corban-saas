import { Calculator } from 'lucide-react'
import { Badge, Card, CardHeader } from '@/components/ui'
import { ClientPicker } from '@/components/ClientPicker'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { effectiveContractTypes } from '@/lib/contract-types'
import { formatCpf } from '@/lib/cpf'
import { parseMoneyInput } from '@/lib/money-input'
import { brlText } from '@/lib/receipts/format'
import { saveOffer } from './actions'
import { SimulatorFilters, type TableOption } from './SimulatorFilters'

const label = 'text-[13px] font-medium text-ink-soft'
// Amounts come from numeric columns; shown through text so no float arithmetic is involved.
const money = (v: number | string | null | undefined) => (v === null || v === undefined ? '—' : brlText(String(v)))
const UUID = /^[0-9a-f-]{36}$/
// Contract types where the client already owes the bank: the outstanding balance (saldo devedor) is asked.
const WITH_BALANCE = new Set(['refinanciamento', 'portabilidade', 'refin_portabilidade', 'compra_de_divida'])
const SOURCE: Record<string, string> = { daily: 'fator diário', fixed: 'fator fixo', table: 'coeficiente da tabela' }

type Offer = {
  table_version_id: string; condition_id: string; table_name: string; bank: string; provider: string | null
  factor: number | string; factor_source: string; factor_date: string | null; term: number
  amount: number | string; installment: number | string; outstanding: number | string | null; change: number | string | null
}
export type SimulatorSp = { cliente?: string; convenio?: string; tipo?: string; tabela?: string; modo?: string; valor?: string; prazo?: string; saldo?: string }

// Simulator (08/10/2026): agreement first, then the contract type, by amount OR by installment, with the term; every
// table of the agreement that has a factor is compared, best first. installment = amount x factor; amount =
// installment / factor. Refin and portability ask the outstanding balance and show the change (troco). The search
// travels in the address as ids and amounts only (never a CPF); the chosen offer is recalculated by the database.
// Used by the Simulações page and by the lead panel in Vendas: keep = hidden fields that keep the panel open,
// client = the lead's client (no picker), back = where "Usar esta" returns.
export async function SimulatorPanel({ sp, keep = {}, client, back }: {
  sp: SimulatorSp; keep?: Record<string, string>; client?: { id: string; full_name: string; cpf: string } | null; back?: string
}) {
  const { supabase, organization } = await requireAppContext()
  const clienteId = client ? client.id : UUID.test(sp.cliente ?? '') ? sp.cliente! : null
  // Table lines (contract types per published version), read in pages: a company can have more than one page of lines.
  const conditionPages = async () => {
    const out: { product_table_version_id: string; contract_type_id: string; coefficient: number | string | null }[] = []
    for (let from = 0; from < 20000; from += 1000) {
      const { data } = await supabase.from('commercial_conditions').select('product_table_version_id,contract_type_id,coefficient').order('id').range(from, from + 999)
      out.push(...((data ?? []) as typeof out))
      if (!data || data.length < 1000) break
    }
    return out
  }
  const [initialClient, agreementsResult, typesResult, settingsResult, tablesResult, versionsResult, conditions, profilesResult] = await Promise.all([
    !client && clienteId ? supabase.from('clients').select('id,full_name,cpf').eq('id', clienteId).is('deleted_at', null).maybeSingle() : Promise.resolve({ data: null }),
    supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name'),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
    supabase.from('product_tables').select('id,name,code,status,bank_table_code,organization_product_routes(org_bank_id,org_agreement_id,status,organization_banks(name))'),
    supabase.from('product_table_versions').select('id,version,product_table_id').eq('status', 'published').limit(5000),
    conditionPages(),
    supabase.from('commercial_factor_profiles').select('org_bank_id,org_agreement_id,product_table_id,bank_table_code').eq('is_active', true),
  ])
  const agreements = (agreementsResult.data ?? []) as { id: string; name: string }[]
  const types = effectiveContractTypes(
    (typesResult.data ?? []) as { id: string; name: string; tech_key: string; is_active: boolean; organization_id: string | null }[],
    (settingsResult.data ?? []) as { contract_type_id: string; is_enabled: boolean; use_in_pipeline: boolean; use_in_commission: boolean }[],
    'pipeline',
  )

  // The search, when complete: agreement, type, mode, value and term.
  const agreement = agreements.find(a => a.id === sp.convenio) ?? null
  const type = types.find(t => t.id === sp.tipo) ?? null
  const mode = sp.modo === 'installment' ? 'installment' : 'amount'
  const value = parseMoneyInput(sp.valor ?? '')
  const term = /^\d{1,3}$/.test(sp.prazo ?? '') ? Number(sp.prazo) : null
  const balanceRaw = parseMoneyInput(sp.saldo ?? '')
  const balance = type && WITH_BALANCE.has(type.tech_key) && balanceRaw && balanceRaw !== 'invalid' ? balanceRaw : null
  const ready = !!agreement && !!type && !!value && value !== 'invalid' && !!term
  // Table choice: one option per bank table (same bank code = same table at every promoter), else per system table.
  type TableRow = { id: string; name: string | null; code: string; status: string; bank_table_code: string | null; organization_product_routes: Route | Route[] | null }
  type Route = { org_bank_id: string; org_agreement_id: string; status: string; organization_banks: { name: string } | { name: string }[] | null }
  const profiles = (profilesResult.data ?? []) as { org_bank_id: string; org_agreement_id: string | null; product_table_id: string | null; bank_table_code: string | null }[]
  const withCoefficient = new Set<string>()
  const tableKey = new Map<string, string>()
  const optionByKey = new Map<string, TableOption>()
  const versionTable = new Map((versionsResult.data ?? []).map(v => [v.id, v.product_table_id]))
  const typesByTable = new Map<string, Set<string>>()
  for (const c of conditions) {
    const t = versionTable.get(c.product_table_version_id)
    if (t) typesByTable.set(t, (typesByTable.get(t) ?? new Set()).add(c.contract_type_id))
    if (t && c.coefficient !== null && Number(c.coefficient) > 0) withCoefficient.add(t)
  }
  for (const t of (tablesResult.data ?? []) as TableRow[]) {
    const route = Array.isArray(t.organization_product_routes) ? t.organization_product_routes[0] : t.organization_product_routes
    if (!route || t.status !== 'active' || route.status !== 'active' || !typesByTable.has(t.id)) continue
    // Only tables that can have a factor: a factor profile that covers them or a coefficient on their lines.
    const covered = withCoefficient.has(t.id) || profiles.some(p => p.org_bank_id === route.org_bank_id && (!p.org_agreement_id || p.org_agreement_id === route.org_agreement_id)
      && (!p.product_table_id || p.product_table_id === t.id) && (!p.bank_table_code || p.bank_table_code === t.bank_table_code))
    if (!covered) continue
    const bankName = (Array.isArray(route.organization_banks) ? route.organization_banks[0] : route.organization_banks)?.name ?? ''
    const key = t.bank_table_code ? `c:${route.org_bank_id}:${t.bank_table_code}` : `t:${t.id}`
    tableKey.set(t.id, key)
    const name = t.name || t.code
    const prev = optionByKey.get(key)
    const plain = t.bank_table_code && !name.startsWith(t.bank_table_code) ? `${t.bank_table_code} · ${name}` : name
    const label = bankName && !plain.toLowerCase().startsWith(bankName.toLowerCase()) ? `${bankName} · ${plain}` : plain
    if (!prev) optionByKey.set(key, { key, label, agreementId: route.org_agreement_id, typeIds: [...typesByTable.get(t.id)!] })
    else {
      prev.typeIds = [...new Set([...prev.typeIds, ...typesByTable.get(t.id)!])]
      if (label.length < prev.label.length) prev.label = label
    }
  }
  const tableOptions = [...optionByKey.values()].sort((a, b) => a.label.localeCompare(b.label, 'pt-BR', { numeric: true }))
  const tableChoice = optionByKey.has(sp.tabela ?? '') ? sp.tabela! : ''
  let offers: Offer[] = []
  let searchError: string | null = null
  // Banks do not work on weekends: daily factors exist only for business days (owner, 08/10/2026).
  const weekday = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Sao_Paulo', weekday: 'short' }).format(new Date())
  const bankHoliday = weekday === 'Sat' || weekday === 'Sun'
  if (ready) {
    const { data, error } = await supabase.rpc('simulation_offers', {
      p_org: organization.id, p_agreement: agreement.id, p_contract_type: type.id, p_term: term, p_mode: mode, p_value: value, p_outstanding: balance,
    })
    if (error) searchError = 'Não foi possível simular agora. Confira os valores e tente de novo.'
    else offers = ((data ?? []) as Offer[]).filter(o => !tableChoice || tableKey.get(versionTable.get(o.table_version_id) ?? '') === tableChoice)
  }
  const withBalance = !!type && WITH_BALANCE.has(type.tech_key)

  return (
    <>
      {!versionsResult.data?.length && <Card className="mb-4 p-5"><p className="text-sm text-muted">Nenhuma tabela publicada ainda. Cadastre as tabelas em Cadastros &gt; Tabelas e os fatores em Cadastros &gt; Fatores.</p></Card>}

      <Card className="mb-4 p-5">
        <form method="get" className="grid gap-4 sm:grid-cols-2 lg:grid-cols-6">
          {Object.entries(keep).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
          {client
            ? <p className={`${label} sm:col-span-2 lg:col-span-6`}>Cliente: <span className="font-semibold text-ink">{client.full_name}</span> <span className="num text-muted">CPF {formatCpf(client.cpf)}</span></p>
            : <div className={`${label} sm:col-span-2 lg:col-span-3`}>Cliente <span className="font-normal text-muted">(para gravar a simulação)</span>
                <ClientPicker optional name="cliente" initial={initialClient.data ? { id: initialClient.data.id, name: initialClient.data.full_name, cpf: formatCpf(initialClient.data.cpf) } : null} />
              </div>}
          <SimulatorFilters agreements={agreements} types={types.map(t => ({ id: t.id, name: t.name }))} tables={tableOptions}
            initial={{ agreement: agreement?.id ?? '', type: type?.id ?? '', table: tableChoice }} />
          <fieldset className={`${label} lg:col-span-2`}>Simular por
            <div className="mt-1.5 flex h-10 items-center gap-4">
              <label className="flex items-center gap-1.5 text-sm text-ink"><input type="radio" name="modo" value="amount" defaultChecked={mode === 'amount'} className="accent-[var(--brand)]" />Valor</label>
              <label className="flex items-center gap-1.5 text-sm text-ink"><input type="radio" name="modo" value="installment" defaultChecked={mode === 'installment'} className="accent-[var(--brand)]" />Parcela</label>
            </div>
          </fieldset>
          <label className={label}>Valor ou parcela (R$)<input required name="valor" defaultValue={sp.valor ?? ''} inputMode="decimal" placeholder="10.000,00" className="field mt-1.5" /></label>
          <label className={label}>Prazo (meses)<input required name="prazo" defaultValue={sp.prazo ?? ''} inputMode="numeric" placeholder="84" className="field mt-1.5" /></label>
          <label className={`${label} lg:col-span-2`}>Saldo devedor (R$) <span className="font-normal text-muted">refin e portabilidade</span>
            <input name="saldo" defaultValue={sp.saldo ?? ''} inputMode="decimal" placeholder="0,00" className="field mt-1.5" /></label>
          <div className="flex items-end sm:col-span-2 lg:col-span-6">
            <button className="inline-flex h-10 items-center justify-center gap-1.5 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong"><Calculator size={15} aria-hidden />Simular</button>
          </div>
        </form>
      </Card>

      {ready && (
        <Card className="mb-6 overflow-hidden">
          <CardHeader title={<span className="flex items-center gap-2">{tableChoice ? optionByKey.get(tableChoice)!.label : `Tabelas para ${agreement!.name}`} · {type!.name} · {term}x <Badge tone="neutral">{offers.length}</Badge></span>} />
          {searchError ? <p role="alert" className="px-5 pb-5 pt-2 text-sm text-[#991B1B]">{searchError}</p> : !offers.length ? (
            <p className="px-5 pb-5 pt-2 text-sm text-muted">{bankHoliday ? 'Hoje é sábado ou domingo: banco sem expediente, sem fator do dia. Simule em dia útil. ' : ''}Nenhuma tabela deste convênio tem fator para {term}x {mode === 'amount' ? 'neste valor' : 'nesta parcela'} hoje{bankHoliday ? '' : ' (em feriado bancário também não há fator)'}. Os fatores ficam em Cadastros &gt; Fatores.</p>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <table className="w-full min-w-[820px] text-left text-sm">
                <thead className="border-y border-line bg-surface-muted text-xs text-muted">
                  <tr><th className="px-5 py-2 font-medium">Tabela</th><th className="px-3 py-2 text-right font-medium">Fator</th><th className="px-3 py-2 text-right font-medium">Parcela</th><th className="px-3 py-2 text-right font-medium">Valor do contrato</th>
                    {withBalance && <><th className="px-3 py-2 text-right font-medium">Saldo devedor</th><th className="px-3 py-2 text-right font-medium">Troco</th></>}<th className="px-5 py-2" /></tr>
                </thead>
                <tbody>
                  {offers.map((o, i) => {
                    const negative = o.change !== null && String(o.change).startsWith('-')
                    return (
                      <tr key={o.table_version_id} className="border-t border-line hover:bg-surface-muted/60">
                        <td className="px-5 py-2.5"><span className="font-medium text-ink">{o.table_name}</span>{i === 0 && <Badge tone="received" className="ml-2">melhor</Badge>}
                          <span className="block text-xs text-muted">{o.provider ? `${o.provider} - ` : ''}{o.bank} · {SOURCE[o.factor_source] ?? o.factor_source}{o.factor_date ? ` de ${o.factor_date.split('-').reverse().join('/')}` : ''}</span></td>
                        <td className="num px-3 py-2.5 text-right text-ink-soft">{String(o.factor).replace('.', ',')}</td>
                        <td className="num whitespace-nowrap px-3 py-2.5 text-right font-semibold text-ink">{money(o.installment)}</td>
                        <td className="num whitespace-nowrap px-3 py-2.5 text-right font-semibold text-ink">{money(o.amount)}</td>
                        {withBalance && <><td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(o.outstanding)}</td>
                          <td className={`num whitespace-nowrap px-3 py-2.5 text-right font-semibold ${negative ? 'text-[#991B1B]' : 'text-[#1D6E4F]'}`}>{money(o.change)}</td></>}
                        <td className="px-5 py-2.5 text-right">
                          {clienteId && !negative ? (
                            <form action={saveOffer}>
                              {[['customer_id', clienteId], ['table_version_id', o.table_version_id], ['condition_id', o.condition_id], ['agreement_id', agreement!.id], ['contract_type_id', type!.id],
                                ['term', String(term)], ['mode', mode], ['value', String(value)], ['outstanding', balance ?? ''], ['back', back ?? '']].map(([n, v]) => <input key={n} type="hidden" name={n} value={v} />)}
                              <SubmitButton className="inline-flex h-8 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong" pendingText="Gravando...">Usar esta</SubmitButton>
                            </form>
                          ) : <span className="text-xs text-muted">{negative ? 'saldo maior que o valor' : 'escolha o cliente'}</span>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
          <p className="px-5 py-3 text-xs text-muted">Parcela = valor × fator; valor = parcela ÷ fator (cortado no centavo para não passar da parcela). Fator diário vale só no dia dele.</p>
        </Card>
      )}
    </>
  )
}
