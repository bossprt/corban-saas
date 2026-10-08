type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']

export type BankOption = { id: string; label: string }
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const bankAccountOf = (f: FormData | string | null | undefined) => {
  const v = String(typeof f === 'string' || f == null ? f ?? '' : f.get('bank_account_id') ?? '').trim()
  return UUID.test(v) ? v : null
}

// The company's active bank accounts and the one to suggest (07/10/2026): the account of the last receipt or payout
// posted with one, else the only account. The person can always pick another or none.
export async function bankAccountChoice(supabase: Supa, source: 'commission_receipt' | 'payout'): Promise<{ banks: BankOption[]; suggested: string }> {
  const [{ data: banks }, { data: last }] = await Promise.all([
    supabase.from('fin_bank_accounts').select('id,label').eq('is_active', true).order('label'),
    supabase.from('fin_entries').select('bank_account_id').eq('source', source).not('bank_account_id', 'is', null).order('created_at', { ascending: false }).limit(1).maybeSingle(),
  ])
  const list = (banks ?? []) as BankOption[]
  const lastId = (last as { bank_account_id: string | null } | null)?.bank_account_id ?? ''
  const suggested = list.some(b => b.id === lastId) ? lastId : list.length === 1 ? list[0].id : ''
  return { banks: list, suggested }
}

// Posts the account on the finance entries of what was just paid or received. A failure here never undoes the
// payment: the person can still set the account in Financeiro.
export async function assignBankAccount(supabase: Supa, organizationId: string, source: 'commission_receipt' | 'payout', refs: string[], bankAccount: string | null) {
  if (!bankAccount || !refs.length) return true
  const { error } = await supabase.rpc('fin_assign_bank_account', { p_org: organizationId, p_source: source, p_refs: refs, p_bank_account: bankAccount })
  return !error
}
