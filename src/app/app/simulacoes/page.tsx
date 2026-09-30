import Link from 'next/link'
import { Calculator } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { ClientPicker } from '@/components/ClientPicker'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { loadProposalCatalog } from '@/lib/proposals/catalog'
import { BankTypeTable } from '@/components/BankTypeTable'
import { formatCpf } from '@/lib/cpf'
import { brlText } from '@/lib/receipts/format'
import { createProposalFromSimulation, createSimulation } from './actions'

const SIM_STATUS: Record<string, [string, Tone]> = {
  draft: ['Rascunho', 'neutral'], calculated: ['Calculada', 'pending'], selected: ['Virou proposta', 'received'], expired: ['Expirada', 'neutral'], cancelled: ['Cancelada', 'reversed'],
}
const label = 'text-[13px] font-medium text-ink-soft'
// Amounts come from numeric columns; shown through text so no float arithmetic is involved.
const money = (v: number | string | null) => (v === null || v === undefined ? '—' : brlText(String(v)))

// ?cliente=<uuid> (never a CPF) opens the form with that client chosen, e.g. from a lead's "Simular".
export default async function SimulationsPage({ searchParams }: { searchParams: Promise<{ cliente?: string }> }) {
  const { supabase, organization } = await requireAppContext()
  const cliente = (await searchParams).cliente ?? ''
  const clienteId = /^[0-9a-f-]{36}$/.test(cliente) ? cliente : null
  const [initialClient, tablesResult, versionsResult, simulationsResult, proposalsResult, catalog] = await Promise.all([
    clienteId ? supabase.from('clients').select('id,full_name,cpf').eq('id', clienteId).is('deleted_at', null).maybeSingle() : Promise.resolve({ data: null }),
    supabase.from('product_tables').select('id,name,code'),
    supabase.from('product_table_versions')
      .select('id,version,product_table_id,term_min,term_max,effective_from,effective_until,published_at,created_at')
      .eq('status', 'published').order('published_at', { ascending: false }).limit(500),
    supabase.from('simulations')
      .select('id,customer_id,product_table_version_id,status,requested_amount,installment_amount,term,created_at,clients(full_name)')
      .order('created_at', { ascending: false }).limit(100),
    supabase.from('proposals_v2').select('id,simulation_id').not('simulation_id', 'is', null),
    loadProposalCatalog(supabase, organization.id),
  ])
  const tableNames = new Map((tablesResult.data ?? []).map(t => [t.id, t.name || t.code]))
  const versionOf = new Map((versionsResult.data ?? []).map(v => [v.id, v]))
  const proposalBySimulation = new Map((proposalsResult.data ?? []).map(p => [p.simulation_id, p.id]))
  const clientName = (s: { clients: { full_name: string } | { full_name: string }[] | null }) => (Array.isArray(s.clients) ? s.clients[0]?.full_name : s.clients?.full_name) ?? 'Cliente'

  return (
    <section>
      <PageHeader title="Simulações" description="Simule o valor da parcela pela tabela publicada e transforme a simulação em proposta com um clique." />

      {!catalog.tables.length && <div role="status" className="mb-4 rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-3 text-sm text-[#92400E]">Nenhuma tabela publicada. Publique uma tabela em Cadastros &gt; Tabelas antes de simular.</div>}

      <Card className="mb-6 p-5">
        <form action={createSimulation} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-6">
          <div className={`${label} sm:col-span-2 lg:col-span-3`}>Cliente
            <ClientPicker name="customer_id" initial={initialClient.data ? { id: initialClient.data.id, name: initialClient.data.full_name, cpf: formatCpf(initialClient.data.cpf) } : null} />
          </div>
          <div className="grid gap-4 sm:col-span-2 sm:grid-cols-3 lg:col-span-6"><BankTypeTable catalog={catalog} versionName="product_table_version_id" typeName="contract_type_id" labelClass={label} /></div>
          <label className={`${label} sm:col-span-2 lg:col-span-3`}>Valor solicitado (R$)<input required name="requested_amount" inputMode="decimal" placeholder="10.000,00" className="field mt-1.5" /></label>
          <label className={`${label} lg:col-span-2`}>Prazo (meses)<input required name="term" inputMode="numeric" placeholder="84" className="field mt-1.5" /></label>
          <div className="flex items-end">
            <SubmitButton className="inline-flex h-10 w-full items-center justify-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Calculando..."><Calculator size={15} aria-hidden />Simular</SubmitButton>
          </div>
        </form>
      </Card>

      <Card className="overflow-hidden">
        <CardHeader title={<span className="flex items-center gap-2">Simulações recentes <Badge tone="neutral">{simulationsResult.data?.length ?? 0}</Badge></span>} />
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[760px] text-left text-sm">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr><th className="px-5 py-2 font-medium">Cliente</th><th className="px-3 py-2 font-medium">Tabela</th><th className="px-3 py-2 text-right font-medium">Solicitado</th><th className="px-3 py-2 text-right font-medium">Parcela</th><th className="px-3 py-2 text-right font-medium">Prazo</th><th className="px-3 py-2 font-medium">Situação</th><th className="px-5 py-2" /></tr>
            </thead>
            <tbody>
              {(simulationsResult.data ?? []).map(s => {
                const proposalId = proposalBySimulation.get(s.id)
                const v = versionOf.get(s.product_table_version_id)
                const [st, tone] = SIM_STATUS[s.status] ?? [s.status, 'neutral' as Tone]
                return (
                  <tr key={s.id} className="border-t border-line hover:bg-surface-muted/60">
                    <td className="px-5 py-2.5"><Link href={`/app/clientes/${s.customer_id}`} className="font-medium text-ink hover:text-brand">{clientName(s)}</Link><span className="block text-xs text-muted">{new Date(s.created_at).toLocaleString('pt-BR')}</span></td>
                    <td className="px-3 py-2.5 text-ink-soft">{v ? `${tableNames.get(v.product_table_id) ?? 'Tabela'} · v${v.version}` : '—'}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(s.requested_amount)}</td>
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
              {!simulationsResult.data?.length && <tr><td colSpan={7} className="px-5 py-10 text-center text-muted">Nenhuma simulação ainda.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
