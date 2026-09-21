
import test from 'node:test'
import assert from 'node:assert/strict'
import { componentEconomics } from '../../src/lib/commission/component-economics'

test('65% of received after 6% tax',()=>{
 const r=componentEconomics({receivedValue:'10',receivedKind:'percentage',discountPct:'6',mode:'share_of_received',sharePct:'65'})
 assert.equal(r.net,'9.4')
 assert.equal(r.payout,'6.11')
 assert.equal(r.retained,'3.29')
})

test('fixed BRL component keeps same unit',()=>{
 const r=componentEconomics({receivedValue:'50',receivedKind:'fixed_brl',discountPct:'6',mode:'share_of_received',sharePct:'80'})
 assert.equal(r.net,'47')
 assert.equal(r.payout,'37.6')
 assert.equal(r.retained,'9.4')
})

test('direct incompatible unit does not invent retained value',()=>{
 const r=componentEconomics({receivedValue:'50',receivedKind:'fixed_brl',discountPct:'0',mode:'direct',directValueKind:'percentage',directValue:'2'})
 assert.equal(r.compatible,false)
 assert.equal(r.retained,null)
})
