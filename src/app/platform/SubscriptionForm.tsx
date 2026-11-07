'use client'

import { useState } from 'react'
import { SubmitButton } from '@/components/SubmitButton'
import { brl, minStartMonth, monthLabel, parseSubscriptionAmount } from '@/lib/billing'
import { saveSubscription } from './actions'

type Sub = { amount: string; due_day: number; grace_days: number; starts_on: string; is_active: boolean }
const button = 'inline-flex h-10 items-center justify-center rounded-none bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'

// One company's subscription. Shows how the typed amount was read ("399.90" and "399,90" are both R$ 399,90) and asks
// for confirmation before saving. The first month cannot be before the current month for a new subscription (the
// database refuses it too); an existing subscription may keep the first month it already has.
export function SubscriptionForm({ orgId, orgName, sub, today }: { orgId: string; orgName: string; sub: Sub | undefined; today: string }) {
  const [amountText, setAmountText] = useState(sub ? sub.amount.replace('.', ',') : '')
  const amount = parseSubscriptionAmount(amountText)
  const minMonth = minStartMonth(today, sub?.starts_on)
  return <form action={saveSubscription} method="post" className="grid gap-3 sm:grid-cols-[1fr_120px_90px_90px_140px_auto_auto] sm:items-end"
    onSubmit={e => {
      const f = new FormData(e.currentTarget)
      const starts = String(f.get('starts_on') ?? '')
      if (!amount || !window.confirm(`${orgName}: cobrar ${brl(amount)} por mês, a partir de ${starts ? monthLabel(`${starts}-01`) : 'o mês escolhido'}, vencendo todo dia ${f.get('due_day')}. Confirmar?`)) e.preventDefault()
    }}>
    <input type="hidden" name="organization_id" value={orgId} />
    <div className="text-sm font-semibold text-ink">{orgName}<div className="text-xs font-normal text-muted">{sub ? (sub.is_active ? 'Cobrança ligada' : 'Cobrança desligada') : 'Sem assinatura'}</div></div>
    <label className="text-xs text-muted">Valor (R$)<input name="amount" required inputMode="decimal" value={amountText} onChange={e => setAmountText(e.target.value)} placeholder="399,90" className="field mt-1 block" aria-describedby={`valor-${orgId}`} />
      <span id={`valor-${orgId}`} className={`mt-1 block ${amountText && !amount ? 'text-[#991B1B]' : ''}`}>{amount ? `${brl(amount)} por mês` : amountText ? 'Valor inválido' : ' '}</span></label>
    <label className="text-xs text-muted">Dia<input name="due_day" required type="number" min={1} max={28} defaultValue={sub?.due_day ?? 3} className="field mt-1 block" /><span className="mt-1 block">&nbsp;</span></label>
    <label className="text-xs text-muted">Carência<input name="grace_days" required type="number" min={0} max={30} defaultValue={sub?.grace_days ?? 5} className="field mt-1 block" /><span className="mt-1 block">&nbsp;</span></label>
    <label className="text-xs text-muted">Primeiro mês<input name="starts_on" required type="month" min={minMonth} defaultValue={sub ? sub.starts_on.slice(0, 7) : today.slice(0, 7)} className="field mt-1 block" />
      <span className="mt-1 block">{sub ? 'Não volta para antes' : 'Do mês atual em diante'}</span></label>
    <label className="flex items-center gap-1.5 text-xs text-muted sm:pb-8"><input type="checkbox" name="is_active" defaultChecked={sub?.is_active ?? true} className="accent-[var(--brand)]" />Ligada</label>
    <div className="sm:pb-5"><SubmitButton pendingText="Salvando..." disabled={!amount} className={button}>Salvar</SubmitButton></div>
  </form>
}
