import type { requireAppContext } from '../appContext'
import { fromDecimalString, toDecimalString } from '../commission/money'

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']

// One account to pay: the exact amount "Pagar agora" pays today and where the money goes (the seller's primary
// account; the favorecido when there is one).
export type PayLine = {
  account: string; name: string; amount: string
  method: 'pix' | 'ted' | null; pixType: string | null; pixKey: string | null
  bankCode: string | null; bankName: string | null; branch: string | null; accountNumber: string | null; accountDigit: string | null; accountType: string | null
  holderName: string | null; holderDocument: string | null; city: string | null
}

type Bank = { seller_id: string; transfer_method: string; pix_key_type: string | null; pix_key: string | null; bank_code: string | null; bank_name: string | null
  branch: string | null; account_number: string | null; account_digit: string | null; account_type: string | null; holder_name: string | null; holder_document: string | null }

export async function loadPayList(supabase: Supa, organizationId: string): Promise<PayLine[]> {
  const { data: rows } = await supabase.rpc('payout_pay_list', { p_org: organizationId })
  const list = (rows ?? []) as { account_id: string; seller_id: string | null; holder_name: string; amount: string | number }[]
  const sellers = [...new Set(list.map(r => r.seller_id).filter((s): s is string => !!s))]
  const [{ data: banks }, { data: profiles }] = sellers.length ? await Promise.all([
    supabase.from('seller_bank_accounts').select('seller_id,transfer_method,pix_key_type,pix_key,bank_code,bank_name,branch,account_number,account_digit,account_type,holder_name,holder_document')
      .in('seller_id', sellers).eq('is_primary', true).is('removed_at', null),
    supabase.from('seller_profiles').select('seller_id,city').in('seller_id', sellers),
  ]) : [{ data: [] }, { data: [] }]
  const bankOf = new Map(((banks ?? []) as Bank[]).map(b => [b.seller_id, b]))
  const cityOf = new Map(((profiles ?? []) as { seller_id: string; city: string | null }[]).map(p => [p.seller_id, p.city]))
  return list.map(r => {
    const b = r.seller_id ? bankOf.get(r.seller_id) : undefined
    return {
      account: r.account_id, name: r.holder_name, amount: toDecimalString(fromDecimalString(String(r.amount)), 2),
      method: b ? (b.transfer_method === 'ted' ? 'ted' : 'pix') : null, pixType: b?.pix_key_type ?? null, pixKey: b?.pix_key ?? null,
      bankCode: b?.bank_code ?? null, bankName: b?.bank_name ?? null, branch: b?.branch ?? null, accountNumber: b?.account_number ?? null,
      accountDigit: b?.account_digit ?? null, accountType: b?.account_type ?? null, holderName: b?.holder_name ?? null, holderDocument: b?.holder_document ?? null,
      city: r.seller_id ? cityOf.get(r.seller_id) ?? null : null,
    }
  })
}
