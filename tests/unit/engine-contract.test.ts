import test from 'node:test'
import assert from 'node:assert/strict'
import { sha256,validateParsedRows,financialEventTypeForAdapter,assertFinancialPublicationAllowed,selectImportAdapter } from '../../src/lib/imports/engine'
import { decimalString,ParsedImportRow } from '../../src/lib/imports/contract'
import { runImportFinancialSemanticContract } from '../../src/lib/imports/semantic-contract'
import { commissionStatementAdapter,paymentStatementAdapter,networkPaymentStatementAdapter,productionStatusAdapter,importAdapters } from '../../src/lib/imports/adapters'

test('semantic contract: commercial-offer adapters can never publish finance',()=>{
 assert.equal(runImportFinancialSemanticContract(),true)
})

test('only statement adapters map to financial event types; production reports never do',()=>{
 assert.equal(financialEventTypeForAdapter(commissionStatementAdapter),'commission_reported')
 assert.equal(financialEventTypeForAdapter(paymentStatementAdapter),'payment_received')
 assert.equal(financialEventTypeForAdapter(networkPaymentStatementAdapter),'downstream_paid')
 assert.equal(financialEventTypeForAdapter(productionStatusAdapter),null)
 assert.throws(()=>assertFinancialPublicationAllowed(productionStatusAdapter))
})

test('no registered adapter besides the three statement adapters can publish financial facts',()=>{
 const allowed=importAdapters.filter(a=>financialEventTypeForAdapter(a)!==null).map(a=>a.key).sort()
 assert.deepEqual(allowed,['generic-commission-statement','generic-network-payment-statement','generic-payment-statement'])
})

test('production adapter promotes to paid only from an explicit canonical status column',()=>{
 const [generic]=productionStatusAdapter.parse({filename:'a.csv',rows:[{Proposta:'1',Status:'Pago'}]})
 assert.equal((generic.normalized.normalizedPayload as {canonicalStatus:string|null}).canonicalStatus,null)
 const [explicit]=productionStatusAdapter.parse({filename:'a.csv',rows:[{Proposta:'1',Status:'x',canonical_status:'paid'}]})
 assert.equal((explicit.normalized.normalizedPayload as {canonicalStatus:string|null}).canonicalStatus,'paid')
})

test('money stays decimal strings (no float drift) and rejects malformed values',()=>{
 assert.equal(decimalString('1.234,56'),'1234.56')
 assert.equal(decimalString('0,10'),'0.10')
 assert.equal(decimalString(''),null)
 assert.equal(decimalString('12,3,4'),null)
 assert.equal(decimalString('abc'),null)
 assert.equal(decimalString('-5,00'),'-5.00')
})

test('SHA-256 is stable so duplicate files replay idempotently',()=>{
 const a=sha256(Buffer.from('same'));const b=sha256('same')
 assert.equal(a,b);assert.match(a,/^[0-9a-f]{64}$/)
 assert.notEqual(a,sha256('other'))
})

test('validateParsedRows rejects duplicate/invalid row numbers (crash/retry safety)',()=>{
 const mk=(n:number):ParsedImportRow=>({rowNumber:n,rawPayload:{},normalized:{recordKind:'other',bankKey:null,externalProposalNumber:null,producerTaxId:null,externalTableCode:null,externalTableName:null,operationType:null,term:null,rate:null,commissionUpfront:null,commissionDeferred:null,amount:null,normalizedPayload:{}}})
 assert.throws(()=>validateParsedRows([mk(1),mk(1)]),/duplicate_row_number/)
 assert.throws(()=>validateParsedRows([mk(0)]),/invalid_row_number/)
 assert.equal(validateParsedRows([mk(1),mk(2)]).length,2)
})

test('adapter selection is explicit for governed sources and ambiguous auto-detection fails closed',()=>{
 assert.equal(selectImportAdapter({filename:'x.csv',sourceKey:'commission_statement'}),commissionStatementAdapter)
 // csv is accepted by several adapters: no unique match without an explicit source key.
 assert.equal(selectImportAdapter({filename:'x.csv'}),null)
})
