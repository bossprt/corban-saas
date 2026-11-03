// Static Pix "copia e cola" (BR Code, EMV QRCPS) for the monthly fee (02/11/2026): key, receiver name and city come from
// the platform settings in the database, the amount and the identifier from the charge. The payer's bank shows the
// receiver's registered name; the name here is only what the code carries (max 25 characters, no accents).
export type PixInput = { key: string; name: string; city: string; amount: string; txid: string }

const field = (id: string, value: string) => `${id}${String(value.length).padStart(2, '0')}${value}`
const ascii = (s: string, max: number) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim().toUpperCase().slice(0, max).trim()

// CRC16/CCITT-FALSE (poly 0x1021, init 0xFFFF), four uppercase hex digits, as the BR Code asks.
export function crc16(s: string): string {
  let crc = 0xffff
  for (const byte of new TextEncoder().encode(s)) {
    crc ^= byte << 8
    for (let i = 0; i < 8; i++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff
  }
  return crc.toString(16).toUpperCase().padStart(4, '0')
}

// "399,90", "399.9" or "399" into "399.90", without floating point; anything else is refused.
export function pixAmount(raw: string): string {
  const m = /^(\d{1,10})(?:[.,](\d{1,2}))?$/.exec(raw.trim())
  if (!m) throw new Error('pix_invalid_amount')
  return `${BigInt(m[1])}.${(m[2] ?? '').padEnd(2, '0')}`
}

export function pixPayload({ key, name, city, amount, txid }: PixInput): string {
  const k = key.trim()
  const id = txid.replace(/[^A-Za-z0-9]/g, '').slice(0, 25) || '***'
  const n = ascii(name, 25), c = ascii(city, 15)
  if (!k || k.length > 77 || !n || !c) throw new Error('pix_invalid_receiver')
  const body = field('00', '01')
    + field('26', field('00', 'br.gov.bcb.pix') + field('01', k))
    + field('52', '0000') + field('53', '986') + field('54', pixAmount(amount))
    + field('58', 'BR') + field('59', n) + field('60', c)
    + field('62', field('05', id))
    + '6304'
  return body + crc16(body)
}
