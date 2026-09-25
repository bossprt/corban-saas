import { isValidCpf } from './cpf'

// Seller registration (owner decision 25/09/2026): labels and document helpers shared by the seller screens.
export const CATEGORY_LABEL: Record<string, string> = { pf: 'PF', pj: 'PJ', sub: 'SUB' }
export const TRANSFER_LABEL: Record<string, string> = { pix: 'PIX', ted: 'TED' }
export const PIX_TYPE_LABEL: Record<string, string> = { cpf_cnpj: 'CPF/CNPJ', phone: 'Celular', email: 'E-mail', random: 'Chave aleatória' }

export type PayTarget = {
  transfer_method: string; pix_key_type: string | null; pix_key: string | null; bank_code: string | null; bank_name: string | null
  branch: string | null; account_number: string | null; account_digit: string | null; holder_name: string | null; holder_document: string | null
}

// The seller's primary account as one line for whoever pays the commission: "PIX (E-mail): x@y" or "TED 104 Caixa · ag. 0001 · 445566-X".
export function payToText(a: PayTarget): string {
  const main = a.transfer_method === 'pix'
    ? `PIX (${PIX_TYPE_LABEL[a.pix_key_type ?? ''] ?? 'chave'}): ${a.pix_key ?? ''}`
    : `TED ${a.bank_code ?? ''} ${a.bank_name ?? ''} · ag. ${a.branch ?? ''} · ${a.account_number ?? ''}${a.account_digit ? `-${a.account_digit}` : ''}`
  return a.holder_name ? `${main} · favorecido: ${a.holder_name} (${formatTaxId(a.holder_document)})` : main
}

export const sellerCode = (n: number | null | undefined) => (n ? String(n).padStart(3, '0') : '—')

export function isValidCnpj(value: string): boolean {
  const d = value.replace(/\D/g, '')
  if (d.length !== 14 || /^(\d)\1{13}$/.test(d)) return false
  const digit = (len: number) => {
    const w = len === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    const r = w.reduce((s, x, i) => s + Number(d[i]) * x, 0) % 11
    return r < 2 ? 0 : 11 - r
  }
  return digit(12) === Number(d[12]) && digit(13) === Number(d[13])
}

export const isValidTaxId = (value: string) => {
  const d = value.replace(/\D/g, '')
  return d.length === 11 ? isValidCpf(d) : d.length === 14 ? isValidCnpj(d) : false
}

// "11144477735" -> "111.444.777-35"; "11222333000181" -> "11.222.333/0001-81"; anything else unchanged.
export function formatTaxId(value: string | null | undefined): string {
  const d = (value ?? '').replace(/\D/g, '')
  if (d.length === 11) return d.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4')
  if (d.length === 14) return d.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5')
  return value ?? ''
}
