import test from 'node:test'
import assert from 'node:assert/strict'
import { detectConflicts,requiresHumanReview,rowContentHash,ConflictRow } from '../../src/lib/imports/conflicts'
import { toCanonicalObservation,proposalIdentityKey } from '../../src/lib/imports/canonical'
import { matchNormalizedRow } from '../../src/lib/imports/matcher'
import { twoTechBuscaContratoAdapter } from '../../src/lib/imports/twotech'
import { NormalizedImportRow } from '../../src/lib/imports/contract'

const norm=(over:Partial<NormalizedImportRow>={},status:Record<string,string>={}):NormalizedImportRow=>({
 recordKind:'proposal',bankKey:'daycoval',externalProposalNumber:'100',producerTaxId:null,externalTableCode:null,externalTableName:null,
 operationType:null,term:null,rate:null,commissionUpfront:null,commissionDeferred:null,amount:null,
 normalizedPayload:{source_status:status},...over
})
let n=0
const row=(o:Partial<ConflictRow>&{normalized?:NormalizedImportRow}={}):ConflictRow=>({
 ref:`r${++n}`,organizationId:'orgA',sourceId:'s1',providerKey:'2tech',batchId:'b1',occurredAt:null,normalized:norm(),...o
})
const kinds=(f:{kind:string}[])=>f.map(x=>x.kind).sort()

test('cross-tenant rows fail closed and are never compared',()=>{
 const f=detectConflicts([row({organizationId:'orgA'}),row({organizationId:'orgB'})])
 assert.deepEqual(kinds(f),['cross_tenant_rows'])
 assert.equal(f[0].severity,'block')
})

test('identical row in same batch is a benign duplicate; in another batch a replay; neither needs review',()=>{
 const a=row(),b=row(),c=row({batchId:'b2'})
 const f=detectConflicts([a,b,c])
 assert.deepEqual(kinds(f),['duplicate_in_batch','replay'])
 assert.ok(f.every(x=>x.severity==='info'))
 assert.equal(requiresHumanReview(f,a.ref),false)
})

test('same proposal from multiple sources requires review',()=>{
 const f=detectConflicts([row({sourceId:'s1'}),row({sourceId:'s2',normalized:norm({},{proposal:'x'})})])
 assert.ok(kinds(f).includes('multi_source_same_proposal'))
})

test('contradictory statuses per dimension are detected independently',()=>{
 const a=row({normalized:norm({},{bank_client:'Pago',company_vendor:'Pendente'})})
 const b=row({sourceId:'s2',normalized:norm({},{bank_client:'Cancelado',company_vendor:'Pendente'})})
 const f=detectConflicts([a,b]).filter(x=>x.kind==='contradictory_status')
 assert.equal(f.length,1)
 assert.equal(f[0].detail.dimension,'bank_client')
 assert.equal(f[0].autoPublishAllowed,false)
})

test('dated conflicting statuses are classified as later_correction but still need review (paid -> cancelled)',()=>{
 const a=row({occurredAt:'2026-01-01',normalized:norm({},{proposal:'Paga'})})
 const b=row({sourceId:'s2',occurredAt:'2026-02-01',normalized:norm({},{proposal:'Cancelada'})})
 const f=detectConflicts([a,b])
 const c=f.find(x=>x.kind==='later_correction')
 assert.ok(c)
 assert.equal(requiresHumanReview(f,a.ref),true)
})

test('missing identity and unknown institution are review findings',()=>{
 const m=row({normalized:norm({externalProposalNumber:null})})
 const u=row({normalized:norm({bankKey:null})})
 const f=detectConflicts([m,u])
 assert.deepEqual(kinds(f),['ambiguous_identity','missing_identity'])
})

test('every finding forbids automatic publication',()=>{
 const f=detectConflicts([row(),row({sourceId:'s2',normalized:norm({},{proposal:'z'})}),row({organizationId:'orgB'})])
 assert.ok(f.every(x=>x.autoPublishAllowed===false))
})

test('content hash is key-order independent',()=>{
 const a=row({normalized:norm({},{a:'1',b:'2'})}),b=row({normalized:norm({},{b:'2',a:'1'})})
 assert.equal(rowContentHash(a),rowContentHash(b))
})

test('canonical identity is provider-independent and provider codes stay aliases',()=>{
 const viaTwoTech=toCanonicalObservation(norm({bankKey:'Daycoval',externalProposalNumber:' 100 '}),'2tech')
 const viaPortal=toCanonicalObservation(norm({bankKey:'daycoval',externalProposalNumber:'100'}),'bank_portal')
 assert.equal(proposalIdentityKey(viaTwoTech.proposalIdentity),proposalIdentityKey(viaPortal.proposalIdentity))
 assert.equal(viaTwoTech.proposalIdentity?.providerKey,'2tech')
 assert.equal(viaPortal.proposalIdentity?.providerKey,'bank_portal')
})

test('canonical observation keeps status dimensions independent and never assigns canonical status',()=>{
 const [r]=twoTechBuscaContratoAdapter.parse({filename:'a.csv',rows:[{NumeroProposta:'9',Banco:'Daycoval',StatusBancoCliente:'A',StatusEmpresaVendedor:'B',StatusProposta:'C'}]})
 const o=toCanonicalObservation(r.normalized,'2tech')
 assert.deepEqual(o.sourceStatuses.map(s=>[s.dimension,s.rawValue]).sort(),[['bank_client','A'],['company_vendor','B'],['proposal','C']])
 assert.ok(o.sourceStatuses.every(s=>s.canonicalStatus===null))
})

test('commission components: blank stays null (not zero), zero stays zero',()=>{
 const o=toCanonicalObservation(norm({commissionUpfront:'0',commissionDeferred:null}),null)
 assert.deepEqual(o.commissionComponents,[{kind:'upfront',value:'0',unit:'unknown'}])
})

test('matcher: duplicated identities and colliding table codes fail closed to human review',()=>{
 const proposals=[{id:'p1',institutionKey:'daycoval',externalProposalNumber:'100'},{id:'p2',institutionKey:'daycoval',externalProposalNumber:'100'}]
 assert.equal(matchNormalizedRow(norm(),{proposals,tables:[]}).strength,'ambiguous')
 const tables=[{id:'t1',channelId:'c1',externalCode:'X'},{id:'t2',channelId:'c2',externalCode:'X'}]
 const m=matchNormalizedRow(norm({externalProposalNumber:null,externalTableCode:'X'}),{proposals:[],tables})
 assert.equal(m.strength,'ambiguous');assert.equal(m.status,'human_required')
 assert.equal(matchNormalizedRow(norm({externalProposalNumber:null}),{proposals:[],tables:[]}).strength,'none')
})

test('matcher: proposal number scoped by institution does not match another institution',()=>{
 const proposals=[{id:'p1',institutionKey:'bevicred',externalProposalNumber:'100'}]
 const m=matchNormalizedRow(norm({bankKey:'daycoval'}),{proposals,tables:[]})
 assert.equal(m.proposalId,null)
 assert.equal(m.strength,'none')
})
