'use client'

import { useState, type ReactNode } from 'react'
import { SubmitButton } from '@/components/SubmitButton'
import { parseMoneyInput } from '@/lib/money-input'

const brl = (c: number) => (c / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
// Cents from the typed value; empty counts as 0, unreadable as null (no float math on money).
const toCents = (v: string): number | null => {
  const p = parseMoneyInput(v)
  if (p === null) return 0
  if (p === 'invalid') return null
  const [i, f = ''] = p.split('.')
  return Number(i) * 100 + Number(f.padEnd(2, '0').slice(0, 2))
}

// "Pagar"/"Receber" with interest, discount, partial payment and receipt (04/11/2026). The database recomputes and
// validates everything; this only shows what will happen before confirming.
export function SettleForm({ action, entryId, returnTo, amountCents, direction, manual, today, defaultBank, bankOptions }: {
  action: (f: FormData) => Promise<void>; entryId: string; returnTo: string; amountCents: number; direction: string; manual: boolean
  today: string; defaultBank: string; bankOptions: ReactNode
}) {
  const [paid, setPaid] = useState((amountCents / 100).toFixed(2).replace('.', ','))
  const [interest, setInterest] = useState('')
  const [discount, setDiscount] = useState('')
  const p = toCents(paid), i = toCents(interest), d = toCents(discount)
  const ok = p !== null && i !== null && d !== null
  const principal = ok ? p - i + d : 0
  const rest = amountCents - principal
  const problem = !ok ? 'Valor em formato não reconhecido.'
    : p <= 0 ? 'Informe o valor pago.'
    : principal > amountCents ? `O valor pago passa do lançamento. Se houve juros ou multa, informe no campo ao lado (sem eles: até ${brl(amountCents + i - d)}).`
    : rest > 0 && !manual ? 'Lançamento automático: só pode ser baixado pelo valor inteiro.' : null
  const verb = direction === 'in' ? 'entra na' : 'sai da'
  const lbl = 'text-xs text-ink-soft'
  return (
    <form action={action} className="mt-1 grid w-[min(30rem,85vw)] gap-2 rounded-none border border-line bg-surface p-3 text-left sm:grid-cols-3">
      <input type="hidden" name="return_to" value={returnTo} /><input type="hidden" name="entry_id" value={entryId} />
      <label className={lbl}>Data<input type="date" name="settled_on" required defaultValue={today} max={today} className="field mt-1 h-8 py-0 text-xs" /></label>
      <label className={lbl}>Conta bancária<select name="bank_account_id" defaultValue={defaultBank} className="field mt-1 h-8 py-0 text-xs"><option value="">Conta?</option>{bankOptions}</select></label>
      <label className={lbl}>{direction === 'in' ? 'Valor recebido' : 'Valor pago'}<input name="paid" value={paid} onChange={e => setPaid(e.target.value)} inputMode="decimal" required className="field mt-1 h-8 py-0 text-xs" /></label>
      <label className={lbl}>Juros e multa (+)<input name="interest" value={interest} onChange={e => setInterest(e.target.value)} inputMode="decimal" placeholder="0,00" className="field mt-1 h-8 py-0 text-xs" /></label>
      <label className={lbl}>Desconto (−)<input name="discount" value={discount} onChange={e => setDiscount(e.target.value)} inputMode="decimal" placeholder="0,00" className="field mt-1 h-8 py-0 text-xs" /></label>
      <label className={lbl}>Comprovante (opcional)<input type="file" name="receipt" accept="application/pdf,image/jpeg,image/png,image/webp" className="mt-1 block w-full text-xs" /></label>
      {problem ? <p role="alert" className="rounded-lg bg-[#FCEBEB] px-2.5 py-1.5 text-xs text-[#991B1B] sm:col-span-3">{problem}</p>
        : rest > 0 ? <p className="rounded-lg bg-[#FAEEDA] px-2.5 py-1.5 text-xs text-[#854F0B] sm:col-span-3">Pagamento parcial: fica em aberto <b>{brl(rest)}</b> com o mesmo vencimento, ligado a este lançamento.</p>
        : null}
      <div className="flex items-center justify-between gap-2 sm:col-span-3">
        <span className="text-xs text-ink-soft">Total que {verb} conta: <b className="num text-ink">{ok && p > 0 ? brl(p) : '—'}</b></span>
        <SubmitButton disabled={!!problem} className="h-8 rounded-lg bg-brand px-3 text-xs font-semibold text-white disabled:opacity-50" pendingText="...">Confirmar</SubmitButton>
      </div>
    </form>
  )
}
