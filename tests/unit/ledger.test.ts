import test from 'node:test'
import assert from 'node:assert/strict'
import { buildLedger,bucketTotals,LedgerEvent } from '../../src/lib/finance/ledger'

let n=0
const ev=(o:Partial<LedgerEvent>&{event_type:string;amount_text:string}):LedgerEvent=>({
 id:o.id??`e${++n}`,component_type:'upfront',currency:'BRL',occurred_at:'2026-01-01T00:00:00Z',created_at:`2026-01-01T00:00:${String(n).padStart(2,'0')}Z`,
 source_kind:'bank_report',source_reference:'ref',reverses_event_id:null,...o
})

test('original -> partial reversals -> net; original is never mutated',()=>{
 const o=ev({id:'pay',event_type:'payment_received',amount_text:'1000'})
 const r1=ev({event_type:'reversal',amount_text:'300',reverses_event_id:'pay'})
 const r2=ev({event_type:'reversal',amount_text:'200.50',reverses_event_id:'pay'})
 const l=buildLedger([r2,o,r1])
 assert.equal(l.entries.length,1)
 assert.equal(l.entries[0].original.amount_text,'1000')
 assert.deepEqual(l.entries[0].reversals.map(r=>r.amount_text),['300','200.50'])
 assert.equal(l.entries[0].reversedTotal,'500.50')
 assert.equal(l.entries[0].net,'499.50')
})

test('buckets subtract reversals from the matching bucket only (mirrors refresh_financial_reconciliation)',()=>{
 const exp=ev({id:'x',event_type:'commission_expected',amount_text:'1000'})
 const rep=ev({id:'r',event_type:'commission_reported',amount_text:'1000'})
 const pay=ev({id:'p',event_type:'payment_received',amount_text:'1000'})
 const b=bucketTotals(buildLedger([exp,rep,pay,
  ev({event_type:'reversal',amount_text:'400',reverses_event_id:'r'}),
  ev({event_type:'reversal',amount_text:'1000',reverses_event_id:'x'})]))
 assert.deepEqual([b.expected,b.reported,b.settled],['0.00','600.00','1000.00'])
 assert.equal(b.difference,'1000.00')
})

test('full reversal nets to zero; nothing goes negative',()=>{
 const pay=ev({id:'p',event_type:'payment_received',amount_text:'0.10'})
 const b=bucketTotals(buildLedger([pay,ev({event_type:'reversal',amount_text:'0.10',reverses_event_id:'p'})]))
 assert.equal(b.settled,'0.00')
})

test('an over-reversal (impossible under the DB guard) is surfaced, not hidden',()=>{
 const pay=ev({id:'p',event_type:'payment_received',amount_text:'10'})
 assert.throws(()=>bucketTotals(buildLedger([pay,ev({event_type:'reversal',amount_text:'11',reverses_event_id:'p'})])),/ledger_negative_bucket/)
})

test('orphan reversals and ungoverned event types are reported separately, never silently merged',()=>{
 const l=buildLedger([ev({event_type:'reversal',amount_text:'5',reverses_event_id:'missing'}),ev({event_type:'adjustment',amount_text:'9'}),ev({event_type:'reversal',amount_text:'1',reverses_event_id:null})])
 assert.equal(l.orphanReversals.length,2)
 assert.equal(l.ungoverned.length,1)
 assert.equal(bucketTotals(l).settled,'0.00')
})

test('decimal strings keep exactness (no float drift)',()=>{
 const a=ev({id:'a',event_type:'commission_reported',amount_text:'0.1'})
 const b=ev({id:'b',event_type:'commission_reported',amount_text:'0.2'})
 assert.equal(bucketTotals(buildLedger([a,b])).reported,'0.30')
})

test('ordering is chronological and stable',()=>{
 const o=ev({id:'o',event_type:'payment_received',amount_text:'100',created_at:'2026-01-01T00:00:00Z'})
 const late=ev({id:'l',event_type:'reversal',amount_text:'10',reverses_event_id:'o',created_at:'2026-03-01T00:00:00Z'})
 const early=ev({id:'e',event_type:'reversal',amount_text:'20',reverses_event_id:'o',created_at:'2026-02-01T00:00:00Z'})
 assert.deepEqual(buildLedger([late,early,o]).entries[0].reversals.map(r=>r.id),['e','l'])
})

test('formatBRL groups thousands without floats and keeps sign/cents',async()=>{
 const { formatBRL }=await import('../../src/lib/finance/ledger')
 assert.equal(formatBRL('1234567.8'),'R$ 1.234.567,80')
 assert.equal(formatBRL('0.1'),'R$ 0,10')
 assert.equal(formatBRL('-15'),'-R$ 15,00')
 assert.equal(formatBRL('99999999999999999999.99'),'R$ 99.999.999.999.999.999.999,99')
 assert.equal(formatBRL(null),'—')
 assert.equal(formatBRL('abc'),'—')
})
