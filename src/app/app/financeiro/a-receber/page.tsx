import Link from 'next/link'
import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { bankAccountChoice } from '@/lib/finBankAccounts'
import { brlText } from '@/lib/receipts/format'
import { isUuid } from '@/lib/team'
import { ReceivableForm, type ReceivableRow } from './ReceivableForm'

const PAGE = 50
type Row = ReceivableRow & { total_count: number; total_expected: string }

// "A receber dos bancos" (audit 06/11/2026): every paid contract whose à vista commission has not been received yet, any age,
// with the expected value. Tick several, check the values and record them in one confirmation.
export default async function ReceivablePage({ searchParams }: { searchParams: Promise<{ fonte?: string; dias?: string; pagina?: string }> }) {
  const sp = await searchParams
  const source = isUuid(sp.fonte ?? '') ? sp.fonte! : null
  const days = sp.dias === '30' ? 30 : 0
  const page = Math.max(1, Math.min(10_000, Number.parseInt(sp.pagina ?? '1', 10) || 1))
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="A receber dos bancos" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const canRecord = can(access, 'financeiro.approve')
  const [{ data, error }, { data: banks }, { data: providers }, choice] = await Promise.all([
    supabase.rpc('commission_receivable', { p_org: organization.id, p_source: source, p_min_days: days, p_limit: PAGE, p_offset: (page - 1) * PAGE }),
    supabase.from('organization_banks').select('id,name').order('name'),
    supabase.from('organization_providers').select('id,name').order('name'),
    canRecord ? bankAccountChoice(supabase, 'commission_receipt') : Promise.resolve({ banks: [], suggested: '' }),
  ])
  const rows = (data ?? []) as Row[]
  const total = rows[0]?.total_count ?? 0
  const pages = Math.max(1, Math.ceil(total / PAGE))
  const qs = (extra: Record<string, string>) => `/app/financeiro/a-receber?${new URLSearchParams(Object.entries({ fonte: source ?? '', dias: days ? String(days) : '', ...extra }).filter(([, v]) => v)).toString()}`
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  const sources = [...(banks ?? []), ...(providers ?? [])]

  return (
    <section>
      <PageHeader title="A receber dos bancos" description="Contratos pagos ao cliente cuja comissão à vista ainda não foi recebida, do mais antigo para o mais novo. Marque os que caíram na conta, confira os valores e registre de uma vez."
        actions={<Link href="/app/financeiro" className="text-sm text-brand hover:underline">Voltar ao financeiro</Link>} />
      <form className="mb-4 flex flex-wrap items-end gap-2" action="/app/financeiro/a-receber">
        <label className="text-[13px] font-medium text-ink-soft">Banco ou promotora
          <select name="fonte" defaultValue={source ?? ''} className="field mt-1.5 min-w-[220px]"><option value="">Todos</option>{sources.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
        </label>
        <label className="text-[13px] font-medium text-ink-soft">Pagos
          <select name="dias" defaultValue={days ? '30' : ''} className="field mt-1.5"><option value="">Qualquer data</option><option value="30">Há mais de 30 dias</option></select>
        </label>
        <button className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Filtrar</button>
      </form>
      {error && <p role="alert" className="mb-4 rounded-[10px] bg-[#FDF3DC] px-4 py-2 text-sm text-[#92400E]">Não foi possível carregar a lista agora. Tente de novo em instantes.</p>}
      <p className="mb-3 text-sm text-ink-soft">{total} contrato(s) · esperado {brlText(rows[0]?.total_expected ?? '0')}</p>
      <ReceivableForm rows={rows.map(r => ({ proposal_id: r.proposal_id, reference: r.reference, client: r.client, source_name: r.source_name, paid_at: r.paid_at, expected_amount: r.expected_amount }))} canRecord={canRecord} banks={choice.banks} suggestedBank={choice.suggested}
        today={today} returnTo={qs(page > 1 ? { pagina: String(page) } : {})} />
      {pages > 1 && (
        <nav aria-label="Páginas" className="mt-3 flex items-center justify-between gap-2 text-sm">
          <span className="text-ink-soft">Página {page} de {pages}</span>
          <span className="flex gap-2">
            {page > 1 && <Link href={qs({ pagina: String(page - 1) })} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Anterior</Link>}
            {page < pages && <Link href={qs({ pagina: String(page + 1) })} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Próxima</Link>}
          </span>
        </nav>
      )}
    </section>
  )
}
