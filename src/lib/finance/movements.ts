import { add, fromDecimalString, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { fetchAll } from '@/lib/fetchAll'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']

export type MovementBank = { id: string; label: string; bank_name: string; opening_balance: string; opening_on: string }
export type Movement = {
  id: string; settled_on: string; description: string; counterpart: string | null; source: string
  amountIn: string | null; amountOut: string | null; balance: string
}
export type Movements = {
  bank: MovementBank; from: string; to: string
  startBalance: string; totalIn: string; totalOut: string; endBalance: string
  rows: Movement[]
  // Entries in the account settled before the opening date: already inside the opening balance, so not listed.
  beforeOpening: number
}

const ISO = /^\d{4}-\d{2}-\d{2}$/
const R = (v: string | number) => fromDecimalString(String(v))
const money = (r: Rational) => toDecimalString(r, 2)

// The period asked for, Brasília days; by default this month up to today. The start never goes before the opening date.
export function movementPeriod(de: string | undefined, ate: string | undefined, openingOn: string) {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  let from = de && ISO.test(de) ? de : `${today.slice(0, 7)}-01`
  const to = ate && ISO.test(ate) ? ate : today
  if (from < openingOn) from = openingOn
  return { from, to: to < from ? from : to }
}

// What came into and left the account (settled entries), oldest first, with the running balance. The balance follows
// the bank balance of the system: the opening balance plus every settled entry from the opening date. Exact decimals.
export async function loadMovements(supabase: Supa, bankId: string, de?: string, ate?: string): Promise<Movements | null> {
  const { data: bank } = await supabase.from('fin_bank_accounts').select('id,label,bank_name,opening_balance,opening_on').eq('id', bankId).maybeSingle()
  if (!bank) return null
  const b = bank as MovementBank
  const { from, to } = movementPeriod(de, ate, b.opening_on)
  type Row = { id: string; direction: string; amount: string; settled_on: string; description: string; counterpart: string | null; source: string; created_at: string }
  const all = await fetchAll<Row>((x, y) => supabase.from('fin_entries')
    .select('id,direction,amount,settled_on,description,counterpart,source,created_at')
    .eq('bank_account_id', bankId).eq('status', 'settled').lte('settled_on', to)
    .order('settled_on').order('created_at').order('id').range(x, y))
  const { count: before } = await supabase.from('fin_entries').select('id', { count: 'exact', head: true })
    .eq('bank_account_id', bankId).eq('status', 'settled').lt('settled_on', b.opening_on)

  let balance = R(b.opening_balance)
  let totalIn = R(0), totalOut = R(0)
  const rows: Movement[] = []
  let start = balance
  for (const e of all) {
    if (e.settled_on < b.opening_on) continue
    if (e.settled_on < from) { balance = e.direction === 'in' ? add(balance, R(e.amount)) : sub(balance, R(e.amount)); continue }
    if (!rows.length) start = balance
    if (e.direction === 'in') { balance = add(balance, R(e.amount)); totalIn = add(totalIn, R(e.amount)) }
    else { balance = sub(balance, R(e.amount)); totalOut = add(totalOut, R(e.amount)) }
    rows.push({
      id: e.id, settled_on: e.settled_on, description: e.description, counterpart: e.counterpart, source: e.source,
      amountIn: e.direction === 'in' ? money(R(e.amount)) : null, amountOut: e.direction === 'in' ? null : money(R(e.amount)), balance: money(balance),
    })
  }
  if (!rows.length) start = balance
  return {
    bank: b, from, to, startBalance: money(start), totalIn: money(totalIn), totalOut: money(totalOut), endBalance: money(balance),
    rows, beforeOpening: before ?? 0,
  }
}
