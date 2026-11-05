// OFX bank statements (C6 Bank, Banco do Brasil, Inter, PagSeguro all export OFX 1.x SGML or 2.x XML). Pure parser: each
// transaction's FITID, posted date, signed amount (as a decimal string, never a float) and memo. Used in the browser, so
// the statement file never has to travel whole.
export type OfxLine = { fitid: string; posted_on: string; amount: string; memo: string }
// A transaction whose date or amount could not be read: shown to the user before importing, never dropped silently.
export type OfxSkipped = { date: string | null; amount: string | null; reason: 'date' | 'amount' }
export type OfxResult = { lines: OfxLine[]; skipped: OfxSkipped[]; account: string | null; error?: 'not_ofx' | 'no_transactions' | 'unreadable' }

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

// "-250.40", "250,40", "+1.234,56" (some banks write the Brazilian way), "1,234.56" -> "-250.40" / "250.40" / "1234.56"
// "1.234" stays unread: it could be 1234 or 1.23.
export const ofxAmount = (raw: string | null): string | null => {
  let s = (raw ?? '').replace(/\s/g, '')
  if (!s) return null
  const neg = s.startsWith('-')
  s = s.replace(/^[+-]/, '')
  if (/^\d{1,3}(\.\d{3})+,\d{1,2}$/.test(s)) s = s.replace(/\./g, '').replace(',', '.')
  else if (/^\d+,\d{1,2}$/.test(s)) s = s.replace(',', '.')
  else if (/^\d{1,3}(,\d{3})+\.\d{1,2}$/.test(s)) s = s.replace(/,/g, '')
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(s)
  if (!m) return null
  const cents = `${m[1].replace(/^0+(?=\d)/, '')}.${(m[2] ?? '').padEnd(2, '0')}`
  if (/^0\.00$/.test(cents)) return null
  return neg ? `-${cents}` : cents
}

const isZero = (raw: string | null) => /^[+-]?0+([.,]0+)?$/.test((raw ?? '').replace(/\s/g, ''))

// The account number written in the file and the one registered for the chosen account: only digits, no leading zeros,
// with or without the check digit at the end. null when either is missing (nothing to compare).
export function sameAccount(fileAccount: string | null, registered: string | null): boolean | null {
  const norm = (v: string | null) => (v ?? '').replace(/\D/g, '').replace(/^0+/, '')
  const a = norm(fileAccount), b = norm(registered)
  if (!a || !b) return null
  return a === b || a.slice(0, -1) === b || b.slice(0, -1) === a
}

export function parseOfx(text: string): OfxResult {
  if (!/<OFX>/i.test(text)) return { lines: [], skipped: [], account: null, error: 'not_ofx' }
  const account = tag(text, 'ACCTID')
  const lines: OfxLine[] = []
  const skipped: OfxSkipped[] = []
  const re = /<STMTTRN>([\s\S]*?)(?=<\/STMTTRN>|<STMTTRN>|<\/BANKTRANLIST>)/gi
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    const b = m[1]
    const posted = ofxDate(tag(b, 'DTPOSTED'))
    const rawAmount = tag(b, 'TRNAMT')
    const amount = ofxAmount(rawAmount)
    if (!posted || !amount) {
      // A zero line is not a transaction; anything else unread is reported.
      if (!(posted && isZero(rawAmount))) skipped.push({ date: posted ?? tag(b, 'DTPOSTED'), amount: rawAmount, reason: posted ? 'amount' : 'date' })
      continue
    }
    const memo = [tag(b, 'NAME'), tag(b, 'MEMO')].filter(Boolean).join(' · ').slice(0, 200)
    // Some exports repeat or omit FITID: fall back to a stable key of the transaction.
    const fitid = (tag(b, 'FITID') || `${posted}|${amount}|${memo}|${lines.length}`).slice(0, 80)
    lines.push({ fitid, posted_on: posted, amount, memo })
  }
  return lines.length ? { lines, skipped, account } : { lines, skipped, account, error: skipped.length ? 'unreadable' : 'no_transactions' }
}
