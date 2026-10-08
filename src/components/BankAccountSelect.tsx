import type { BankOption } from '@/lib/finBankAccounts'

// The company bank account the money came into or left from (07/10/2026). Optional: it can be set later in Financeiro.
export function BankAccountSelect({ banks, suggested, label, labelClass, selectClass }:
  { banks: BankOption[]; suggested: string; label: string; labelClass?: string; selectClass?: string }) {
  if (!banks.length) return null
  return (
    <label className={labelClass ?? 'text-[13px] font-medium text-ink-soft'}>{label}
      <select name="bank_account_id" defaultValue={suggested} className={selectClass ?? 'field mt-1.5'}>
        <option value="">Não informar agora</option>
        {banks.map(b => <option key={b.id} value={b.id}>{b.label}</option>)}
      </select>
    </label>
  )
}
