import Link from 'next/link'
import type { BillingStatus } from '@/lib/appContext'
import { dayLabel, monthLabel } from '@/lib/billing'

// Notice for the company's administrator from the due day until the fee is paid: red once it is overdue (grace days).
export function BillingNotice({ billing }: { billing: BillingStatus }) {
  if (!billing.period || !billing.block_on) return null
  const last = new Date(`${billing.block_on}T12:00:00Z`)
  last.setUTCDate(last.getUTCDate() - 1)
  const until = dayLabel(last.toISOString().slice(0, 10))
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' })
  return (
    <p role="alert" className={`mb-5 flex flex-wrap items-center justify-between gap-2 rounded-none border px-4 py-3 text-sm ${billing.overdue ? 'border-[#F5C2C0] bg-[#FDE2E1] text-[#991B1B]' : 'border-[#FDE68A] bg-[#FEF3C7] text-[#92400E]'}`}>
      <span>{billing.overdue
        ? `Mensalidade de ${monthLabel(billing.period)} vencida. Pague até ${until} para não bloquear o acesso da empresa.`
        : `A mensalidade de ${monthLabel(billing.period)} vence ${billing.due_on === today ? 'hoje' : `em ${billing.due_on ? dayLabel(billing.due_on) : 'breve'}`}.`}</span>
      <Link href="/mensalidade" className="font-semibold underline">Pagar agora</Link>
    </p>
  )
}
