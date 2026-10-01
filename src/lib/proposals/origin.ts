import { parseMoneyInput } from '@/lib/money-input'

// Saldo devedor and origin of a refinancing or portability (record only). Money goes as decimal text, never a float.
export function originDetails(f: FormData): { ok: true; details: Record<string, string> } | { ok: false } {
  const text = (k: string) => String(f.get(k) ?? '').trim()
  const balance = parseMoneyInput(text('outstanding_balance'))
  if (balance === 'invalid') return { ok: false }
  const details: Record<string, string> = {}
  if (f.has('outstanding_balance')) details.outstanding_balance = balance ?? ''
  if (f.has('origin_bank_name')) details.origin_bank_name = text('origin_bank_name').slice(0, 120)
  if (f.has('origin_contract_number')) details.origin_contract_number = text('origin_contract_number').slice(0, 60)
  return { ok: true, details }
}
