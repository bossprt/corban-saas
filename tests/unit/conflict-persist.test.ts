import test from 'node:test'
import assert from 'node:assert/strict'
import { buildBatchFindings } from '../../src/lib/imports/conflict-persist'
import { twoTechBuscaContratoAdapter } from '../../src/lib/imports/twotech'

const ctx={organizationId:'o',sourceId:'s',providerKey:'2tech',batchId:'b'}
const ids=(n:number)=>new Map(Array.from({length:n},(_,i)=>[i+1,`raw-${i+1}`]))
const parse=(rows:Record<string,unknown>[])=>twoTechBuscaContratoAdapter.parse({filename:'a.csv',rows})

test('duplicate identical rows in one batch become duplicate_row with both raw row ids as evidence',()=>{
 const rows=parse([{NumeroProposta:'1',Banco:'Daycoval',StatusProposta:'x'},{NumeroProposta:'1',Banco:'Daycoval',StatusProposta:'x'}])
 const f=buildBatchFindings(rows,ctx,ids(2))
 const d=f.find(x=>x.kind==='duplicate_row')
 assert.ok(d);assert.deepEqual(d!.rawRowIds,['raw-1','raw-2']);assert.equal(d!.severity,'info')
})

test('unknown schema is persisted once per reason with every affected raw row; no fingerprint is invented',()=>{
 const rows=parse([{Foo:'1'},{Foo:'2'}])
 const f=buildBatchFindings(rows,ctx,ids(2))
 assert.equal(f.length,1)
 assert.equal(f[0].kind,'unknown_schema');assert.equal(f[0].detail.reason,'missing_proposal_identity_column');assert.deepEqual(f[0].rawRowIds,['raw-1','raw-2'])
})

test('a row without identity in an otherwise known schema is a missing_identity finding',()=>{
 const rows=parse([{NumeroProposta:'1',StatusProposta:'a'},{NumeroProposta:'',StatusProposta:'b'}])
 const f=buildBatchFindings(rows,ctx,ids(2))
 assert.ok(f.some(x=>x.kind==='missing_identity'&&x.rawRowIds.join()==='raw-2'))
})

test('findings without a persisted raw row are dropped (evidence must exist), and payload carries no financial fields',()=>{
 const rows=parse([{NumeroProposta:'1',Banco:'D',StatusProposta:'x'},{NumeroProposta:'1',Banco:'D',StatusProposta:'x'}])
 assert.deepEqual(buildBatchFindings(rows,ctx,new Map()),[])
 const f=buildBatchFindings(rows,ctx,ids(2))
 assert.ok(f.every(x=>!('amount' in x)&&!('autoPublishAllowed' in x)))
})
