import Link from 'next/link'
import { ChevronRight, FilePlus2 } from 'lucide-react'
import { Badge, Card, CardHeader } from '@/components/ui'
import { cmp, div, fromDecimalString, isZero, mul, sub, toDecimalString } from '@/lib/commission/money'
import { brlText } from '@/lib/receipts/format'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type Num = string | number
type Board = {
  seller: boolean; name?: string
  goal?: { target: Num; paid: Num; count: number }
  expected?: Num; released?: Num; received_month?: Num
  pending?: { id: string; client: string | null; ade: string | null; reason: string | null; due: string | null }[]
  recent?: { id: string; client: string | null; ade: string | null; amount: Num; status: string; stage: string | null; payable: Num; waiting: string | null; paid_on: string | null }[]
}

const R = (v: Num | null | undefined) => fromDecimalString(String(v ?? 0))
const money = (v: Num | null | undefined) => brlText(toDecimalString(R(v), 2))
const dateBr = (iso: string) => new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })
const nowMs = () => Date.now()
const daysLeftInMonth = () => {
  const [y, m, d] = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date()).split('-').map(Number)
  return new Date(Date.UTC(y, m, 0)).getUTCDate() - d
}
const WAITING: Record<string, string> = {
  client: 'aguardando pagamento ao cliente', physical: 'aguardando o físico', calculation: 'aguardando cálculo',
  bank: 'aguardando comissão do banco', divergent: 'comissão do banco em análise', no_payout: 'sem comissão para você',
}
const STATUS: Record<string, string> = { paid: 'Pago ao cliente', cancelled: 'Cancelado', rejected: 'Recusado' }

// The seller's dashboard (06/10/2026, model F, mobile first): the month's goal, what they will earn (expected, released
// for the next payment, received this month), their bank pendencies and latest contracts. Only their own numbers.
export async function SellerDashboard({ supabase, organizationId }: { supabase: Supa; organizationId: string }) {
  const { data, error } = await supabase.rpc('seller_dashboard', { p_org: organizationId })
  const b = data as Board | null
  if (error || !b) return <Card className="p-5 text-sm text-[#92400E]">Não foi possível carregar seus números agora. Tente de novo em instantes.</Card>

  const target = R(b.goal?.target), paid = R(b.goal?.paid)
  const pct = isZero(target) ? null : Math.min(999, Number(toDecimalString(mul(div(paid, target), R(100)), 0)))
  const missing = isZero(target) || cmp(paid, target) >= 0 ? null : sub(target, paid)
  const ring = pct === null ? 0 : Math.min(100, pct)
  const circ = 2 * Math.PI * 34
  const now = nowMs()
  const first = (b.name ?? '').split(/\s+/)[0]

  return (
    <section className="mx-auto max-w-xl">
      <div className="mb-4 flex items-center justify-between gap-3">
        <div><p className="text-sm text-ink-soft">Olá{first ? `, ${first.charAt(0)}${first.slice(1).toLowerCase()}` : ''}</p><h1 className="text-xl font-semibold text-ink">Seu mês</h1></div>
        <Link href="/app/propostas/nova" className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong"><FilePlus2 size={16} aria-hidden />Novo contrato</Link>
      </div>

      <Card className="mb-4 p-5">
        <div className="flex items-center gap-4">
          <svg viewBox="0 0 80 80" className="size-24 shrink-0" role="img" aria-label={pct === null ? 'Sem meta definida' : `Meta ${pct}% atingida`}>
            <circle cx="40" cy="40" r="34" fill="none" strokeWidth="9" stroke="currentColor" opacity="0.12" />
            {pct !== null && <circle cx="40" cy="40" r="34" fill="none" strokeWidth="9" strokeLinecap="round" stroke={pct >= 90 ? '#1D9E75' : pct >= 60 ? '#EF9F27' : '#E24B4A'}
              strokeDasharray={`${(ring / 100) * circ} ${circ}`} transform="rotate(-90 40 40)" />}
            <text x="40" y="45" textAnchor="middle" className="fill-current text-[15px] font-semibold">{pct === null ? '—' : `${pct}%`}</text>
          </svg>
          <div className="min-w-0">
            <p className="text-xs text-muted">Meta do mês</p>
            <p className="num text-lg font-semibold text-ink">{money(b.goal?.paid)}{!isZero(target) && <span className="text-sm font-normal text-ink-soft"> de {money(b.goal?.target)}</span>}</p>
            <p className="text-xs text-ink-soft">{b.goal?.count ?? 0} contrato(s) pago(s) · {missing ? `faltam ${money(toDecimalString(missing, 2))} em ${daysLeftInMonth()} dia(s)` : isZero(target) ? 'meta ainda não definida' : 'meta batida'}</p>
          </div>
        </div>
      </Card>

      <Card className="mb-4">
        <CardHeader title="Quanto você vai ganhar" />
        <div className="grid grid-cols-3 gap-2 px-5 pb-5 pt-3 text-center">
          <div className="rounded-[12px] bg-surface-muted px-2 py-3"><p className="text-[11px] text-muted">Previsto</p><p className="num whitespace-nowrap text-[13px] font-semibold sm:text-base text-ink">{money(b.expected)}</p><p className="text-[10px] text-muted">contratos em andamento</p></div>
          <div className="rounded-[12px] bg-surface-muted px-2 py-3"><p className="text-[11px] text-muted">Liberado</p><p className="num whitespace-nowrap text-[13px] font-semibold sm:text-base text-[#1D6E4F]">{money(b.released)}</p><p className="text-[10px] text-muted">no próximo pagamento</p></div>
          <div className="rounded-[12px] bg-surface-muted px-2 py-3"><p className="text-[11px] text-muted">Recebido</p><p className="num whitespace-nowrap text-[13px] font-semibold sm:text-base text-ink">{money(b.received_month)}</p><p className="text-[10px] text-muted">neste mês</p></div>
        </div>
        <Link href="/app/repasse" className="flex items-center justify-between border-t border-line px-5 py-3 text-sm text-brand hover:bg-surface-muted">Ver meu extrato <ChevronRight size={16} aria-hidden /></Link>
      </Card>

      <Card className="mb-4">
        <CardHeader title={<span className="flex items-center gap-2">Minhas pendências <Badge tone={b.pending?.length ? 'pending' : 'neutral'}>{b.pending?.length ?? 0}</Badge></span>} />
        {!b.pending?.length ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nenhuma pendência no banco.</p> : (
          <ul className="mt-2">{b.pending.map(p => {
            const late = !!p.due && new Date(p.due).getTime() < now
            return (
              <li key={p.id}><Link href={`/app/propostas/${p.id}`} className="flex items-center justify-between gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
                <span className="min-w-0"><span className="block truncate text-sm font-medium text-ink">{p.client ?? 'Contrato'}{p.ade ? <span className="font-normal text-muted"> · nº {p.ade}</span> : null}</span>
                  <span className={`block truncate text-[13px] ${late ? 'text-[#B91C1C]' : 'text-[#92400E]'}`}>{p.reason ?? 'Pendência no banco'}{p.due ? ` · prazo ${dateBr(p.due)}${late ? ' (vencido)' : ''}` : ''}</span></span>
                <ChevronRight size={16} aria-hidden className="shrink-0 text-muted" />
              </Link></li>
            )
          })}</ul>
        )}
      </Card>

      <Card>
        <CardHeader title="Últimos contratos" />
        {!b.recent?.length ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Você ainda não tem contratos.</p> : (
          <ul className="mt-2">{b.recent.map(r => (
            <li key={r.id}><Link href={`/app/propostas/${r.id}`} className="flex items-center justify-between gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
              <span className="min-w-0"><span className="block truncate text-sm font-medium text-ink">{r.client ?? 'Contrato'}</span>
                <span className="block truncate text-[12px] text-ink-soft">{money(r.amount)} · {STATUS[r.status] ?? r.stage ?? 'Em andamento'}</span></span>
              <span className="shrink-0 text-right"><span className="num block text-sm font-semibold text-ink">{money(r.payable)}</span>
                <span className="block text-[11px] text-muted">{r.paid_on ? `recebido em ${dateBr(r.paid_on)}` : r.waiting ? WAITING[r.waiting] ?? r.waiting : 'liberado'}</span></span>
            </Link></li>
          ))}</ul>
        )}
      </Card>
      <p className="mt-6 text-center text-xs text-muted">Só os seus contratos e a sua parte da comissão.</p>
    </section>
  )
}
