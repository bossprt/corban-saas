import type { Tone } from '@/components/ui/Badge'

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
