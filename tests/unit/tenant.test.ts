import test from 'node:test'
import assert from 'node:assert/strict'
import { resolveActiveMembership,scopeToOrganization,TENANT_FREE_TABLES } from '../../src/lib/tenant'

const A='11111111-1111-4111-8111-111111111111'
const B='22222222-2222-4222-8222-222222222222'
const C='33333333-3333-4333-8333-333333333333'
const m=(o:string,role='agent')=>({organization_id:o,role})

test('no membership -> none; exactly one -> that one regardless of cookie',()=>{
 assert.deepEqual(resolveActiveMembership([],A),{kind:'none'})
 assert.deepEqual(resolveActiveMembership([m(A)],undefined),{kind:'active',membership:m(A)})
 assert.deepEqual(resolveActiveMembership([m(A)],B),{kind:'active',membership:m(A)})
})

test('several memberships: the explicit cookie selects, but only if still an ACTIVE membership; never an implicit pick',()=>{
 const two=[m(A,'supervisor'),m(B,'admin')]
 assert.deepEqual(resolveActiveMembership(two,B),{kind:'active',membership:m(B,'admin')})
 assert.deepEqual(resolveActiveMembership(two,B.toUpperCase()),{kind:'active',membership:m(B,'admin')})
 for(const bad of [undefined,null,'',C,'not-a-uuid',`${A}; drop`,'*']){
  const r=resolveActiveMembership(two,bad as string|undefined)
  assert.equal(r.kind,'choose',String(bad))
 }
})

test('a role always comes from the membership row of the selected organization',()=>{
 const r=resolveActiveMembership([m(A,'agent'),m(B,'admin')],A)
 assert.equal(r.kind==='active'&&r.membership.role,'agent')
})

test('duplicate membership rows collapse (still deterministic)',()=>{
 assert.equal(resolveActiveMembership([m(A),m(A)],undefined).kind,'active')
})

function fakeClient(){
 const calls:string[]=[]
 const builder=(table:string)=>{
  const b:Record<string,unknown>={
   select:(...a:unknown[])=>{calls.push(`${table}.select(${a.join(',')})`);return b},
   update:()=>{calls.push(`${table}.update`);return b},
   delete:()=>{calls.push(`${table}.delete`);return b},
   insert:()=>{calls.push(`${table}.insert`);return b},
   eq:(c:string,v:unknown)=>{calls.push(`${table}.eq(${c},${v})`);return b},
   order:()=>{calls.push(`${table}.order`);return b}
  }
  return b
 }
 return {calls,client:{from:builder,rpc:(n:string)=>{calls.push(`rpc(${n})`);return 'rpc-result'}}}
}

test('scoped client filters select/update/delete on tenant tables to the active organization',()=>{
 const f=fakeClient()
 const s=scopeToOrganization(f.client,A)
 ;(s.from('clients') as unknown as {select:(c:string)=>{eq:(c:string,v:string)=>unknown}}).select('id').eq('id','x')
 ;(s.from('proposals_v2') as unknown as {update:(v:object)=>{eq:(c:string,v:string)=>unknown}}).update({status:'x'}).eq('id','y')
 ;(s.from('clients') as unknown as {delete:()=>unknown}).delete()
 assert.deepEqual(f.calls,['clients.select(id)',`clients.eq(organization_id,${A})`,'clients.eq(id,x)','proposals_v2.update',`proposals_v2.eq(organization_id,${A})`,'proposals_v2.eq(id,y)','clients.delete',`clients.eq(organization_id,${A})`])
})

test('global catalog tables are not filtered; insert and rpc pass through untouched',()=>{
 const f=fakeClient()
 const s=scopeToOrganization(f.client,A)
 ;(s.from('banks') as unknown as {select:(c:string)=>unknown}).select('*')
 ;(s.from('organizations') as unknown as {select:(c:string)=>unknown}).select('id')
 ;(s.from('clients') as unknown as {insert:(v:object)=>unknown}).insert({organization_id:A})
 assert.equal((s as unknown as {rpc:(n:string)=>string}).rpc('x'),'rpc-result')
 assert.deepEqual(f.calls,['banks.select(*)','organizations.select(id)','clients.insert','rpc(x)'])
})

test('the free-table list matches the live schema (tables WITHOUT organization_id)',()=>{
 assert.equal(TENANT_FREE_TABLES.size,12) // + contract_types, national_agreement_templates (Commercial Model V3)
 assert.ok(TENANT_FREE_TABLES.has('organizations')&&!TENANT_FREE_TABLES.has('clients')&&!TENANT_FREE_TABLES.has('organization_memberships'))
})
