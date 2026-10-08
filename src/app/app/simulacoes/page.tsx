import Link from 'next/link'
import { Calculator } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { ClientPicker } from '@/components/ClientPicker'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { effectiveContractTypes } from '@/lib/contract-types'
import { formatCpf } from '@/lib/cpf'
import { parseMoneyInput } from '@/lib/money-input'
import { brlText } from '@/lib/receipts/format'
import { createProposalFromSimulation, saveOffer } from './actions'

const SIM_STATUS: Record<string, [string, Tone]> = {
  draft: ['Rascunho', 'neutral'], calculated: ['Calculada', 'pending'], selected: ['Virou proposta', 'received'], expired: ['Expirada', 'neutral'], cancelled: ['Cancelada', 'reversed'],
}
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
type Sp = { cliente?: string; convenio?: string; tipo?: string; modo?: string; valor?: string; prazo?: string; saldo?: string }

// Simulator (08/10/2026): agreement first, then the contract type, by amount OR by installment, with the term; every
// table of the agreement that has a factor is compared, best first. installment = amount x factor; amount =
// installment / factor. Refin and portability ask the outstanding balance and show the change (troco). The search
// travels in the address as ids and amounts only (never a CPF); the chosen offer is recalculated by the database.
export default async function SimulationsPage({ searchParams }: { searchParams: Promise<Sp> }) {
  const { supabase, organization } = await requireAppContext()
  const sp = await searchParams
  const clienteId = UUID.test(sp.cliente ?? '') ? sp.cliente! : null
  const [initialClient, agreementsResult, typesResult, settingsResult, simulationsResult, proposalsResult, tablesResult, versionsResult] = await Promise.all([
    clienteId ? supabase.from('clients').select('id,full_name,cpf').eq('id', clienteId).is('deleted_at', null).maybeSingle() : Promise.resolve({ data: null }),
    supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name'),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
    supabase.from('simulations')
      .select('id,customer_id,product_table_version_id,status,requested_amount,released_amount,installment_amount,term,created_at,clients(full_name)')
      .order('created_at', { ascending: false }).limit(50),
    supabase.from('proposals_v2').select('id,simulation_id').not('simulation_id', 'is', null),
    supabase.from('product_tables').select('id,name,code'),
    supabase.from('product_table_versions').select('id,version,product_table_id').eq('status', 'published').limit(1000),
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
    else offers = (data ?? []) as Offer[]
  }

  const tableNames = new Map((tablesResult.data ?? []).map(t => [t.id, t.name || t.code]))
  const versionOf = new Map((versionsResult.data ?? []).map(v => [v.id, v]))
  const proposalBySimulation = new Map((proposalsResult.data ?? []).map(p => [p.simulation_id, p.id]))
  const clientName = (s: { clients: { full_name: string } | { full_name: string }[] | null }) => (Array.isArray(s.clients) ? s.clients[0]?.full_name : s.clients?.full_name) ?? 'Cliente'
  const withBalance = !!type && WITH_BALANCE.has(type.tech_key)

  return (
    <section>
      <PageHeader title="Simulações" description="Escolha o convênio e simule por valor ou por parcela: o Corban compara todas as tabelas que têm fator e mostra a melhor primeiro." />
      {!versionsResult.data?.length && <Card className="mb-4 p-5"><p className="text-sm text-muted">Nenhuma tabela publicada ainda. Cadastre as tabelas em Cadastros &gt; Tabelas e os fatores em Cadastros &gt; Fatores.</p></Card>}

      <Card className="mb-4 p-5">
        <form method="get" className="grid gap-4 sm:grid-cols-2 lg:grid-cols-6">
          <div className={`${label} sm:col-span-2 lg:col-span-3`}>Cliente <span className="font-normal text-muted">(para gravar a simulação)</span>
            <ClientPicker name="cliente" initial={initialClient.data ? { id: initialClient.data.id, name: initialClient.data.full_name, cpf: formatCpf(initialClient.data.cpf) } : null} />
          </div>
          <label className={`${label} lg:col-span-2`}>Convênio
            <select name="convenio" required defaultValue={agreement?.id ?? ''} className="field mt-1.5">
              <option value="" disabled>Escolha</option>
              {agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select>
          </label>
          <label className={label}>Operação
            <select name="tipo" required defaultValue={type?.id ?? ''} className="field mt-1.5">
              <option value="" disabled>Escolha</option>
              {types.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </label>
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
          <CardHeader title={<span className="flex items-center gap-2">Tabelas para {agreement!.name} · {type!.name} · {term}x <Badge tone="neutral">{offers.length}</Badge></span>} />
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
                                ['term', String(term)], ['mode', mode], ['value', String(value)], ['outstanding', balance ?? '']].map(([n, v]) => <input key={n} type="hidden" name={n} value={v} />)}
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

      <Card className="overflow-hidden">
        <CardHeader title={<span className="flex items-center gap-2">Simulações gravadas <Badge tone="neutral">{simulationsResult.data?.length ?? 0}</Badge></span>} />
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[760px] text-left text-sm">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr><th className="px-5 py-2 font-medium">Cliente</th><th className="px-3 py-2 font-medium">Tabela</th><th className="px-3 py-2 text-right font-medium">Contrato</th><th className="px-3 py-2 text-right font-medium">Liberado</th><th className="px-3 py-2 text-right font-medium">Parcela</th><th className="px-3 py-2 text-right font-medium">Prazo</th><th className="px-3 py-2 font-medium">Situação</th><th className="px-5 py-2" /></tr>
            </thead>
            <tbody>
              {(simulationsResult.data ?? []).map(s => {
                const proposalId = proposalBySimulation.get(s.id)
                const v = versionOf.get(s.product_table_version_id)
                const [st, tone] = SIM_STATUS[s.status] ?? [s.status, 'neutral' as Tone]
                return (
                  <tr key={s.id} className="border-t border-line hover:bg-surface-muted/60">
                    <td className="px-5 py-2.5"><Link href={`/app/clientes/${s.customer_id}`} className="font-medium text-ink hover:text-brand">{clientName(s)}</Link><span className="block text-xs text-muted">{new Date(s.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</span></td>
                    <td className="px-3 py-2.5 text-ink-soft">{v ? `${tableNames.get(v.product_table_id) ?? 'Tabela'} · v${v.version}` : '—'}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(s.requested_amount)}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(s.released_amount ?? s.requested_amount)}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right font-medium text-ink">{s.installment_amount === null ? 'Não calculada' : money(s.installment_amount)}</td>
                    <td className="num px-3 py-2.5 text-right">{s.term ?? '—'}</td>
                    <td className="px-3 py-2.5"><Badge tone={tone}>{st}</Badge></td>
                    <td className="px-5 py-2.5 text-right">
                      {proposalId
                        ? <Link href={`/app/propostas/${proposalId}`} className="text-sm font-medium text-brand hover:underline">Abrir proposta</Link>
                        : <form action={createProposalFromSimulation}>
                            <input type="hidden" name="simulation_id" value={s.id} />
                            <SubmitButton className="inline-flex h-8 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong" pendingText="Criando...">Criar proposta</SubmitButton>
                          </form>}
                    </td>
                  </tr>
                )
              })}
              {!simulationsResult.data?.length && <tr><td colSpan={8} className="px-5 py-10 text-center text-muted">Nenhuma simulação gravada ainda.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
