// OFX bank statements (C6 Bank, Banco do Brasil, Inter, PagSeguro all export OFX 1.x SGML or 2.x XML). Pure parser: each
// transaction's FITID, posted date, signed amount (as a decimal string, never a float) and memo. Used in the browser, so
// the statement file never has to travel whole.
export type OfxLine = { fitid: string; posted_on: string; amount: string; memo: string }
export type OfxResult = { lines: OfxLine[]; account: string | null; error?: 'not_ofx' | 'no_transactions' }

const tag = (block: string, name: string): string | null => {
  const m = new RegExp(`<${name}>([^<\\r\\n]*)`, 'i').exec(block)
  return m ? m[1].trim() : null
}

// "20260915120000[-3:BRT]" or "20260915" -> "2026-09-15"
export const ofxDate = (raw: string | null): string | null => {
  const m = /^(\d{4})(\d{2})(\d{2})/.exec(raw ?? '')
  if (!m) return null
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]))
  return d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3] ? `${m[1]}-${m[2]}-${m[3]}` : null
}

// "-250.40", "250,40", "+1.234,56" (some banks write the Brazilian way) -> "-250.40" / "250.40" / "1234.56"
export const ofxAmount = (raw: string | null): string | null => {
  let s = (raw ?? '').replace(/\s/g, '')
  if (!s) return null
  const neg = s.startsWith('-')
  s = s.replace(/^[+-]/, '')
  if (/^\d{1,3}(\.\d{3})+,\d{1,2}$/.test(s)) s = s.replace(/\./g, '').replace(',', '.')
  else if (/^\d+,\d{1,2}$/.test(s)) s = s.replace(',', '.')
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(s)
  if (!m) return null
  const cents = `${m[1].replace(/^0+(?=\d)/, '')}.${(m[2] ?? '').padEnd(2, '0')}`
  if (/^0\.00$/.test(cents)) return null
  return neg ? `-${cents}` : cents
}

export function parseOfx(text: string): OfxResult {
  if (!/<OFX>/i.test(text)) return { lines: [], account: null, error: 'not_ofx' }
  const account = tag(text, 'ACCTID')
  const lines: OfxLine[] = []
  const re = /<STMTTRN>([\s\S]*?)(?=<\/STMTTRN>|<STMTTRN>|<\/BANKTRANLIST>)/gi
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    const b = m[1]
    const posted = ofxDate(tag(b, 'DTPOSTED'))
    const amount = ofxAmount(tag(b, 'TRNAMT'))
    if (!posted || !amount) continue
    const memo = [tag(b, 'NAME'), tag(b, 'MEMO')].filter(Boolean).join(' · ').slice(0, 200)
    // Some exports repeat or omit FITID: fall back to a stable key of the transaction.
    const fitid = (tag(b, 'FITID') || `${posted}|${amount}|${memo}|${lines.length}`).slice(0, 80)
    lines.push({ fitid, posted_on: posted, amount, memo })
  }
  return lines.length ? { lines, account } : { lines, account, error: 'no_transactions' }
}
