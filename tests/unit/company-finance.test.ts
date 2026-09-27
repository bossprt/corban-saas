import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ofxAmount, ofxDate, parseOfx } from '../../src/lib/finance/ofx'
import { DRE_ORDER, FIN_KIND_LABEL } from '../../src/lib/finance/labels'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')

// SGML (OFX 1.x, Banco do Brasil / C6 style: no closing tags on values) and XML (OFX 2.x, Inter / PagSeguro style).
const SGML = `OFXHEADER:100
DATA:OFXSGML
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKACCTFROM><BANKID>336<ACCTID>123456<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST><DTSTART>20260901<DTEND>20260930
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260915120000[-3:BRT]<TRNAMT>-250.40<FITID>A1<MEMO>PAG CONTA ENERGIA
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260916<TRNAMT>600,00<FITID>A2<NAME>TED<MEMO>BANCO TESTE
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260917<TRNAMT>-1.234,56<FITID>A3<MEMO>PIX ENVIADO
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`
const XML = `<?xml version="1.0"?><OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260920</DTPOSTED><TRNAMT>-12.9</TRNAMT><FITID>X1</FITID><MEMO>TARIFA</MEMO></STMTTRN>
<STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260921</DTPOSTED><TRNAMT>0.00</TRNAMT><FITID>X2</FITID><MEMO>ZERO</MEMO></STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`

test('OFX 1.x (SGML): every transaction with FITID, date, signed amount as text and memo', () => {
  const r = parseOfx(SGML)
  assert.equal(r.error, undefined)
  assert.equal(r.account, '123456')
  assert.deepEqual(r.lines, [
    { fitid: 'A1', posted_on: '2026-09-15', amount: '-250.40', memo: 'PAG CONTA ENERGIA' },
    { fitid: 'A2', posted_on: '2026-09-16', amount: '600.00', memo: 'TED · BANCO TESTE' },
    { fitid: 'A3', posted_on: '2026-09-17', amount: '-1234.56', memo: 'PIX ENVIADO' },
  ])
})

test('OFX 2.x (XML): closing tags accepted; a zero line is not a transaction', () => {
  assert.deepEqual(parseOfx(XML).lines, [{ fitid: 'X1', posted_on: '2026-09-20', amount: '-12.90', memo: 'TARIFA' }])
})

test('OFX: anything else is refused, never guessed', () => {
  assert.equal(parseOfx('Data;Valor\n01/01/2026;10').error, 'not_ofx')
  assert.equal(parseOfx('<OFX></OFX>').error, 'no_transactions')
  assert.equal(ofxDate('20260231'), null)
  assert.equal(ofxAmount('12,345'), null)
  assert.equal(ofxAmount('1e3'), null)
  assert.equal(ofxAmount('-0,5'), '-0.50')
})

test('income statement order covers every kind but transfers, which stay out of it', () => {
  assert.deepEqual(DRE_ORDER.map(r => r.kind).sort(), Object.keys(FIN_KIND_LABEL).filter(k => k !== 'transfer').sort())
  const m = read('supabase/migrations/20260927600000_company_finance_v1.sql')
  assert.match(m, /a\.kind <> 'transfer'/)
  assert.doesNotMatch(m, /\b(real|double precision|float)\b/i)
  assert.match(m, /revoke all on public\.fin_chart_accounts, public\.fin_bank_accounts, public\.fin_settings, public\.fin_entries/)
})
