import test from 'node:test'
import assert from 'node:assert/strict'
import { componentEconomics } from '../../src/lib/commission/component-economics'

test('6% tax then 65% of received keeps 3.29 points for the company',()=>{
 const r=componentEconomics({receivedValue:'10',receivedKind:'percentage',discountPct:'6',mode:'share_of_received',sharePct:'65'})
 assert.deepEqual(r,{gross:'10',net:'9.4',payout:'6.11',retained:'3.29',payoutKind:'percentage',compatible:true})
})

test('fixed BRL component uses the same deterministic math',()=>{
 const r=componentEconomics({receivedValue:'50',receivedKind:'fixed_brl',discountPct:'6',mode:'share_of_received',sharePct:'80'})
 assert.equal(r.net,'47');assert.equal(r.payout,'37.6');assert.equal(r.retained,'9.4')
})

test('direct payout with a different unit never invents retained value',()=>{
 const r=componentEconomics({receivedValue:'50',receivedKind:'fixed_brl',discountPct:'0',mode:'direct',directValueKind:'percentage',directValue:'2'})
 assert.equal(r.compatible,false);assert.equal(r.retained,null)
})
