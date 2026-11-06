import type { Tone } from '@/components/ui/Badge'
import { parseMoneyInput } from './money-input'

// Monthly fee (03/11/2026): labels shared by the company's fee page and /platform.
export const CHARGE_STATE: Record<string, [string, Tone]> = {
  paid: ['Paga', 'received'],
  open: ['Em aberto', 'expected'],
  overdue: ['Vencida', 'diverged'],
  blocking: ['Bloqueando o acesso', 'reversed'],
}

const MONTHS = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez']
// "2026-11-01" → "nov/2026"; "2026-11-03" → "03/11/2026". Dates come from the database as plain days.
export const monthLabel = (iso: string) => `${MONTHS[Number(iso.slice(5, 7)) - 1]}/${iso.slice(0, 4)}`
export const dayLabel = (iso: string) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`
// "399.90" → "R$ 399,90" without floating point.
export const brl = (amount: string) => {
  const [int, dec = '00'] = amount.split('.')
  return `R$ ${int.replace(/\B(?=(\d{3})+(?!\d))/g, '.')},${dec.padEnd(2, '0').slice(0, 2)}`
}

// Subscription amount typed on /platform ("399,90", "399.90", "1.234,56", "R$ 399") → "399.90", or null when it is not
// a positive amount with at most 8 integer digits. Reuses parseMoneyInput, so "399.90" is never read as 39990.
export function parseSubscriptionAmount(raw: unknown): string | null {
  const v = parseMoneyInput(raw)
  if (v === null || v === 'invalid' || !/^\d{1,8}\.\d{2}$/.test(v) || /^0+\.00$/.test(v)) return null
  return v
}

// "2026-11-06" → "2026-11": the earliest first month a subscription may have. A new subscription starts this month or
// later (a past month would create charges already overdue and block the company at once); an existing one may keep
// the first month it already has. The database enforces the same rule (platform_set_subscription).
export function minStartMonth(today: string, currentStartsOn?: string | null): string {
  const month = today.slice(0, 7)
  const existing = currentStartsOn ? currentStartsOn.slice(0, 7) : null
  return existing && existing < month ? existing : month
}
