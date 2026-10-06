// Static PIX "copia e cola" (BR Code, Banco Central's EMV QR layout) for paying a seller: the key, the exact amount, the
// receiver's name and city. Scanned in any bank app, it fills the key and the amount; the bank shows the key owner's
// real name before the payment is confirmed. Built here, no bank integration (owner request 06/10/2026).

// Field = id (2 digits) + length (2 digits) + value.
const field = (id: string, value: string) => `${id}${String(value.length).padStart(2, '0')}${value}`

// CRC16-CCITT (poly 0x1021, initial 0xFFFF), over the whole code including "6304" (BR Code manual).
export function crc16(text: string): string {
  let crc = 0xffff
  for (const byte of new TextEncoder().encode(text)) {
    crc ^= byte << 8
    for (let i = 0; i < 8; i++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff
  }
  return crc.toString(16).toUpperCase().padStart(4, '0')
}

// Names and cities go without accents or symbols, in capitals, cut to the field size.
const plain = (s: string, max: number) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim().toUpperCase().slice(0, max)

// The key as the PIX directory stores it: CPF/CNPJ digits, phone +55..., e-mail in lower case, random key as is.
export function pixKey(type: string | null | undefined, key: string): string | null {
  const k = key.trim()
  if (!k) return null
  if (type === 'cpf_cnpj') { const d = k.replace(/\D/g, ''); return d.length === 11 || d.length === 14 ? d : null }
  if (type === 'phone') {
    const d = k.replace(/\D/g, '')
    const full = d.length === 10 || d.length === 11 ? `55${d}` : d
    return /^55\d{10,11}$/.test(full) ? `+${full}` : null
  }
  if (type === 'email') return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(k) ? k.toLowerCase() : null
  if (type === 'random') return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(k) ? k.toLowerCase() : null
  return null
}

// amount: decimal string with two places ("1250.00"), never a float. Returns null when the key or amount is unusable.
export function pixCopyPaste({ keyType, key, amount, name, city }: { keyType: string | null | undefined; key: string; amount: string; name: string; city?: string | null }): string | null {
  const k = pixKey(keyType, key)
  if (!k || !/^\d{1,10}\.\d{2}$/.test(amount) || amount === '0.00') return null
  const body =
    field('00', '01') +
    field('26', field('00', 'br.gov.bcb.pix') + field('01', k)) +
    field('52', '0000') +
    field('53', '986') +
    field('54', amount) +
    field('58', 'BR') +
    field('59', plain(name, 25) || 'RECEBEDOR') +
    field('60', plain(city ?? '', 15) || 'BRASIL') +
    field('62', field('05', '***')) +
    '6304'
  return body + crc16(body)
}
