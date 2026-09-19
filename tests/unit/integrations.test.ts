import test from 'node:test'
import assert from 'node:assert/strict'
import { executeRun, requestFingerprint, backoffSeconds, type ExecutionRequest } from '../../src/lib/integrations/executor'
import { InMemoryRunRepository, RepositoryError, SupabaseRunRepository } from '../../src/lib/integrations/repository'
import { FAKE_FILE_MANIFEST, FAKE_MANIFEST, ScriptedProvider, type FakeStep } from '../../src/lib/integrations/fake-provider'
import { capabilityNames, declares, parseProviderResult, type CapabilityManifest, type CredentialProvider } from '../../src/lib/integrations/contract'
import { redact, redactString, maskTaxId, REDACTED } from '../../src/lib/integrations/redact'
import { MemoryLogger, sanitizeEvent } from '../../src/lib/integrations/observability'

const creds:CredentialProvider={get:async()=>undefined}
const req=(over:Partial<ExecutionRequest>={}):ExecutionRequest=>({organizationId:'o1',bindingId:'b1',actorUserId:'u1',capability:'status',payload:{proposal:'100'},...over})
const T0=Date.parse('2026-09-21T10:00:00Z')
const at=(ms:number)=>()=>new Date(T0+ms)
const run=(repo:InMemoryRunRepository,adapter:ScriptedProvider,ms=0,over:Partial<Parameters<typeof executeRun>[0]>={})=>executeRun({repo,adapter,request:req(),credentials:creds,now:at(ms),timeoutMs:200,...over})
const prov=(...s:FakeStep[])=>new ScriptedProvider(s.length?s:[{kind:'success'}])

// ---------- happy path, evidence, redaction ----------
test('end to end: request -> executor -> repository -> provider -> evidence -> succeeded',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'success',externalRequestId:'ext-1'})
 const out=await run(repo,p)
 assert.equal(out.state,'succeeded');assert.equal(out.state==='succeeded'&&out.externalRequestId,'ext-1')
 const stored=[...repo.runs.values()][0]
 assert.equal(stored.status,'succeeded');assert.equal(stored.attemptCount,1);assert.equal(stored.claimToken,null)
 assert.equal(stored.artifacts.some(a=>a.kind==='response_metadata'),true)
 assert.equal(p.calls[0].call.idempotencyKey,requestFingerprint(req(),'local/fake'))
})

test('secrets never reach the run, artifacts, errors or logs',async()=>{
 const repo=new InMemoryRunRepository();const logger=new MemoryLogger()
 await executeRun({repo,adapter:prov({kind:'leaky'}),request:req({payload:{proposal:'100',password:'hunter2',nested:{token:'abc12345678',cpf:'123.456.789-01'}}}),credentials:creds,now:at(0),logger})
 const dump=JSON.stringify([...repo.runs.values()])+JSON.stringify(logger.events)
 for(const secret of['abcdef0123456789abcdef','sk_live_abcdef123456','hunter2','hunter2pass','abc12345678','12345678901','123.456.789-01','sid=1','abcd1234efgh'])assert.equal(dump.includes(secret),false,`leaked: ${secret}`)
 assert.equal(dump.includes(REDACTED),true)
})

test('a provider cannot declare success without deterministic evidence (malformed shapes are terminal, never success)',async()=>{
 for(const shape of['not_object','no_ok','no_artifacts','no_response_evidence','bad_kind'] as const){
  const repo=new InMemoryRunRepository();const out=await run(repo,prov({kind:'malformed',shape}))
  assert.equal(out.state,'failed',shape);assert.equal(out.state==='failed'&&out.errorCode,'terminal:malformed_response',shape)
  assert.equal([...repo.runs.values()][0].status,'failed');assert.equal(repo.artifacts.length,0)
  const again=await run(repo,prov({kind:'success'}),60_000);assert.equal(again.state,'failed')  // terminal: not silently retried into success
 }
 assert.equal(parseProviderResult({ok:true,artifacts:[{kind:'response_metadata',payload:{}}]}).ok,true)
 assert.equal(parseProviderResult({ok:true,externalRequestId:'x'.repeat(201),artifacts:[{kind:'response_metadata',payload:{}}]}).ok,false)
})

// ---------- idempotency / concurrency ----------
test('idempotent: the same request executes once and replays the stored success',async()=>{
 const repo=new InMemoryRunRepository();const p=prov()
 const first=await run(repo,p,0);const second=await run(repo,p,5000)
 assert.equal(first.state,'succeeded');assert.equal(second.state==='succeeded'&&second.replayed,true)
 assert.equal(p.calls.length,1);assert.equal(repo.runs.size,1)
})

test('two workers, same idempotency key, at the same time: exactly one calls the provider',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'delayed',delayMs:30})
 const [a,b]=await Promise.all([run(repo,p),run(repo,p)])
 const states=[a.state,b.state].sort()
 assert.deepEqual(states,['in_progress','succeeded']);assert.equal(p.calls.length,1);assert.equal(repo.runs.size,1)
})

test('N workers racing: one provider call, one run',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'delayed',delayMs:20})
 const outs=await Promise.all(Array.from({length:8},()=>run(repo,p)))
 assert.equal(outs.filter(o=>o.state==='succeeded').length,1);assert.equal(outs.filter(o=>o.state==='in_progress').length,7)
 assert.equal(p.calls.length,1)
})

test('worker dies after claim: lease expiry lets another worker take over (counts an attempt), the dead worker cannot commit late',async()=>{
 const repo=new InMemoryRunRepository();const fp=requestFingerprint(req(),'local/fake')
 const dead=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'u1',maxAttempts:3,leaseSeconds:300,request:{},correlationId:'c',now:new Date(T0)})
 const busy=await run(repo,prov(),299_000);assert.equal(busy.state,'in_progress')
 const p=prov();const took=await run(repo,p,301_000)
 assert.equal(took.state,'succeeded');assert.equal([...repo.runs.values()][0].attemptCount,2)
 const late=await repo.complete({organizationId:'o1',runId:dead.runId,claimToken:dead.claimToken!,externalRequestId:'zombie',artifacts:[{kind:'response_metadata',payload:{},sha256:'z'}],now:new Date(T0+400_000)})
 assert.equal(late,'conflicting_duplicate');assert.notEqual([...repo.runs.values()][0].externalRequestId,'zombie')
})

test('worker dies after the provider call but before commit: recovery re-calls with the SAME idempotency key; the zombie is fenced off',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'success',externalRequestId:'ext-A'})
 const fp=requestFingerprint(req(),'local/fake')
 const w1=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'u1',maxAttempts:3,leaseSeconds:60,request:{},correlationId:'c1',now:new Date(T0)})
 // w1 called the provider (not recorded) and crashed. w2 takes over after the lease expired.
 const out=await run(repo,p,61_000,{leaseSeconds:60})
 assert.equal(out.state,'succeeded');assert.equal(p.calls[0].call.idempotencyKey,fp)
 const zombie=await repo.complete({organizationId:'o1',runId:w1.runId,claimToken:w1.claimToken!,externalRequestId:'ext-ZOMBIE',artifacts:[{kind:'response_metadata',payload:{},sha256:'q'}],now:new Date(T0+70_000)})
 assert.equal(zombie,'conflicting_duplicate');assert.equal([...repo.runs.values()][0].externalRequestId,'ext-A')
})

test('a late commit from a worker whose lease expired but who was NOT replaced is accepted (no second submission)',async()=>{
 const repo=new InMemoryRunRepository();const fp=requestFingerprint(req(),'local/fake')
 const c=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'u1',maxAttempts:3,leaseSeconds:60,request:{},correlationId:'c',now:new Date(T0)})
 const r=await repo.complete({organizationId:'o1',runId:c.runId,claimToken:c.claimToken!,externalRequestId:'e',artifacts:[{kind:'response_metadata',payload:{},sha256:'s'}],now:new Date(T0+3_600_000)})
 assert.equal(r,'succeeded')
})

test('crash on the last attempt is a terminal failure, never assumed successful and never retried past the bound',async()=>{
 const repo=new InMemoryRunRepository();const fp=requestFingerprint(req(),'local/fake')
 await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'u1',maxAttempts:1,leaseSeconds:60,request:{},correlationId:'c',now:new Date(T0)})
 const p=prov();const out=await run(repo,p,61_000,{maxAttempts:1,leaseSeconds:60})
 assert.equal(out.state,'failed');assert.equal(p.calls.length,0)
})

// ---------- failure handling ----------
test('timeout is retryable, backs off, and is not retried early',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'timeout'},{kind:'success'})
 const r1=await run(repo,p,0,{timeoutMs:20});assert.equal(r1.state,'retry_scheduled')
 assert.equal([...repo.runs.values()][0].errorCode,'timeout')
 assert.equal((await run(repo,p,backoffSeconds(1)*1000-1000,{timeoutMs:20})).state,'retry_scheduled');assert.equal(p.calls.length,1)
 const r2=await run(repo,p,backoffSeconds(1)*1000,{timeoutMs:20});assert.equal(r2.state,'succeeded');assert.equal(p.calls.length,2)
 assert.equal([...repo.runs.values()][0].attemptCount,2)
})

test('transient failures stop after maxAttempts and become terminal',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'transient'})
 let t=0;const states:string[]=[]
 for(let i=0;i<5;i++){const o=await run(repo,p,t,{maxAttempts:3});states.push(o.state);t+=backoffSeconds(i+1)*1000+1}
 assert.deepEqual(states,['retry_scheduled','retry_scheduled','failed','failed','failed']);assert.equal(p.calls.length,3)
})

test('permanent failure is terminal and never re-executes',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'permanent',code:'invalid_proposal'})
 const o=await run(repo,p);assert.equal(o.state==='failed'&&o.errorCode,'terminal:invalid_proposal')
 assert.equal((await run(repo,p,3_600_000)).state,'failed');assert.equal(p.calls.length,1)
})

test('adapter exception is retryable and its message is redacted',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'throws',message:'boom Authorization: Bearer abcdef0123456789xyz'})
 const o=await run(repo,p);assert.equal(o.state,'retry_scheduled')
 const r=[...repo.runs.values()][0];assert.equal(r.errorCode,'adapter_exception');assert.equal(String(r.errorMessage).includes('abcdef0123456789xyz'),false)
})

test('duplicate provider result: same id is ignored, a different id never overwrites',async()=>{
 const repo=new InMemoryRunRepository();const p=prov({kind:'success',externalRequestId:'X'})
 const o=await run(repo,p);assert.equal(o.state,'succeeded')
 const r=[...repo.runs.values()][0]
 const arts=[{kind:'response_metadata' as const,payload:{a:1},sha256:'k'}]
 assert.equal(await repo.complete({organizationId:'o1',runId:r.id,claimToken:'whatever',externalRequestId:'X',artifacts:arts,now:new Date(T0)}),'duplicate_ignored')
 assert.equal(await repo.complete({organizationId:'o1',runId:r.id,claimToken:'whatever',externalRequestId:'Y',artifacts:arts,now:new Date(T0)}),'conflicting_duplicate')
 assert.equal(r.externalRequestId,'X')
})

test('artifact duplicates (same run, kind, hash) are stored once',async()=>{
 const repo=new InMemoryRunRepository();const fp=requestFingerprint(req(),'local/fake')
 const c=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'u1',maxAttempts:3,leaseSeconds:60,request:{},correlationId:'c',now:new Date(T0)})
 const a={kind:'response_metadata' as const,payload:{x:1},sha256:'same'}
 await repo.complete({organizationId:'o1',runId:c.runId,claimToken:c.claimToken!,externalRequestId:'e',artifacts:[a,a],now:new Date(T0)})
 assert.equal(repo.artifacts.length,1)
})

// ---------- tenant / authorization ----------
const orgs:Record<string,{members:Record<string,string>;bindings:Record<string,{adapterKey:string;capabilities:string[]}>}>={
 o1:{members:{u1:'supervisor',ua:'agent',ur:'revoked'},bindings:{b1:{adapterKey:'local/fake',capabilities:capabilityNames(FAKE_MANIFEST)}}},
 o2:{members:{u2:'admin'},bindings:{b2:{adapterKey:'local/fake',capabilities:capabilityNames(FAKE_MANIFEST)}}}
}
const guarded=(over?:Partial<{revoke:boolean}>)=>new InMemoryRunRepository({
 isMember:(o,u,roles)=>!over?.revoke&&roles.includes(orgs[o]?.members[u]??''),
 binding:(o,b)=>orgs[o]?.bindings[b]??null
})

test('tenant A cannot run against tenant B binding UUID, agent/revoked/unknown users are refused, nothing is created',async()=>{
 const repo=guarded()
 await assert.rejects(()=>run(repo,prov(),0,{request:req({organizationId:'o1',bindingId:'b2'})}),(e:RepositoryError)=>e.code==='binding_not_found')
 await assert.rejects(()=>run(repo,prov(),0,{request:req({organizationId:'o2',bindingId:'b1',actorUserId:'u2'})}),(e:RepositoryError)=>e.code==='binding_not_found')
 for(const u of['ua','ur','ghost','u2'])await assert.rejects(()=>run(repo,prov(),0,{request:req({actorUserId:u})}),(e:RepositoryError)=>e.code==='actor_not_authorized',u)
 assert.equal(repo.runs.size,0)
})

test('same payload in two tenants are independent runs',async()=>{
 const repo=guarded();const p=prov()
 await run(repo,p,0);await run(repo,p,0,{request:req({organizationId:'o2',bindingId:'b2',actorUserId:'u2'})})
 assert.equal(repo.runs.size,2);assert.equal(p.calls.length,2)
})

test('membership revoked mid-flow: in-flight result is still recorded, but no new work and no retry',async()=>{
 let revoked=false
 const repo=new InMemoryRunRepository({isMember:(o,u,roles)=>!revoked&&roles.includes(orgs[o]?.members[u]??''),binding:(o,b)=>orgs[o]?.bindings[b]??null})
 const p:ScriptedProvider=new ScriptedProvider([{kind:'delayed',delayMs:30}])
 const inflight=run(repo,p);await new Promise(r=>setTimeout(r,5));revoked=true
 assert.equal((await inflight).state,'succeeded')
 await assert.rejects(()=>run(repo,prov(),0,{request:req({payload:{other:1}})}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 const repo2=new InMemoryRunRepository({isMember:()=>!revoked,binding:(o,b)=>orgs[o]?.bindings[b]??null})
 revoked=false;await run(repo2,prov({kind:'transient'}),0);revoked=true
 await assert.rejects(()=>run(repo2,prov(),3_600_000),(e:RepositoryError)=>e.code==='actor_not_authorized')
})

// ---------- guards on the state machine (in-memory twin) ----------
test('cancelled runs are never resumed; succeeded runs cannot be cancelled; only manager+ may cancel',async()=>{
 const repo=new InMemoryRunRepository({isMember:(o,u,roles)=>roles.includes(orgs[o]?.members[u]??''),binding:(o,b)=>orgs[o]?.bindings[b]??null})
 await run(repo,prov({kind:'transient'}),0)
 const id=[...repo.runs.keys()][0]
 await assert.rejects(()=>repo.cancel({organizationId:'o1',runId:id,actorUserId:'u1'}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 orgs.o1.members.um='manager'
 assert.equal(await repo.cancel({organizationId:'o1',runId:id,actorUserId:'um'}),'cancelled')
 const p=prov();assert.equal((await run(repo,p,3_600_000)).state,'failed');assert.equal(p.calls.length,0)
 const repo2=guarded();await run(repo2,prov(),0)
 orgs.o1.members.um='manager'
 await assert.rejects(()=>repo2.cancel({organizationId:'o1',runId:[...repo2.runs.keys()][0],actorUserId:'um'}),(e:RepositoryError)=>e.code==='illegal_integration_run_transition')
})

// ---------- capability discovery / refusals ----------
test('capability discovery: behaviour follows the manifest, not the provider name',async()=>{
 assert.equal(declares(FAKE_MANIFEST,'submit'),true);assert.equal(declares(FAKE_FILE_MANIFEST,'submit'),false)
 assert.deepEqual(capabilityNames(FAKE_FILE_MANIFEST),['contract_lookup','status'])
 const repo=new InMemoryRunRepository();const p=new ScriptedProvider([{kind:'success'}],FAKE_FILE_MANIFEST)
 const o=await executeRun({repo,adapter:p,request:req({capability:'submit'}),credentials:creds,now:at(0)})
 assert.deepEqual(o,{state:'refused',reason:'capability_unavailable'});assert.equal(repo.runs.size,0)
 assert.equal((await executeRun({repo,adapter:p,request:req({capability:'contract_lookup'}),credentials:creds,now:at(0),timeoutMs:200})).state,'succeeded')
})

test('Bevicred is DEFERRED and always refused; external providers are blocked unless explicitly allowed',async()=>{
 const repo=new InMemoryRunRepository()
 const bevi:CapabilityManifest={...FAKE_MANIFEST,provider:'bevi',adapterKey:'bevi/webservice_agente',external:true}
 for(const allowExternal of[false,true]){
  const o=await executeRun({repo,adapter:new ScriptedProvider([{kind:'success'}],bevi),request:req(),credentials:creds,now:at(0),allowExternal})
  assert.deepEqual(o,{state:'refused',reason:'provider_deferred'})
 }
 const ext:CapabilityManifest={...FAKE_MANIFEST,adapterKey:'acme/api',provider:'acme',external:true}
 const pe=new ScriptedProvider([{kind:'success'}],ext)
 assert.deepEqual(await executeRun({repo,adapter:pe,request:req(),credentials:creds,now:at(0)}),{state:'refused',reason:'external_not_allowed'})
 assert.equal(pe.calls.length,0);assert.equal(repo.runs.size,0)
})

test('adapter/binding mismatch is refused before any provider call',async()=>{
 const repo=new InMemoryRunRepository({binding:()=>({adapterKey:'2tech/busca_contrato_file',capabilities:['status']})})
 const p=prov();const o=await run(repo,p);assert.deepEqual(o,{state:'refused',reason:'adapter_mismatch'});assert.equal(p.calls.length,0)
})

// ---------- observability ----------
test('events are a whitelist with correlation, run, provider, adapter, attempt, duration, outcome and sanitized error',async()=>{
 const repo=new InMemoryRunRepository();const logger=new MemoryLogger()
 await executeRun({repo,adapter:prov({kind:'transient'}),request:req({correlationId:'corr-9',payload:{password:'p4ss'}}),credentials:creds,now:at(0),logger})
 assert.equal(logger.events.every(e=>e.correlationId==='corr-9'&&e.provider==='local'&&e.adapter==='local/fake'),true)
 const called=logger.events.find(e=>e.event==='provider_called')!;assert.equal(typeof called.durationMs,'number');assert.equal(called.attempt,1)
 assert.equal(logger.events.some(e=>e.event==='run_retry_scheduled'&&e.errorCode==='provider_unavailable'),true)
 assert.equal(JSON.stringify(logger.events).includes('p4ss'),false)
 const s=sanitizeEvent({event:'run_failed',level:'error',correlationId:'c',provider:'p',adapter:'a',capability:'x',errorMessage:'x Authorization: Bearer abcdefghijklmnop y',payload:{secret:1}} as never)
 assert.equal('payload' in s,false);assert.equal(String(s.errorMessage).includes('abcdefghijklmnop'),false)
})

// ---------- Supabase repository mapping ----------
test('SupabaseRunRepository maps to the worker functions, surfaces only stable error tokens',async()=>{
 const calls:{fn:string;args:Record<string,unknown>}[]=[]
 const okRow={run_id:'r1',outcome:'claimed',claim_token:'t1',attempt_count:1,status:'running',next_attempt_at:null,external_request_id:null,error_code:null}
 const client={rpc:async(fn:string,args:Record<string,unknown>)=>{calls.push({fn,args});
  if(fn==='claim_integration_run')return {data:[okRow],error:null}
  if(fn==='complete_integration_run')return {data:'succeeded',error:null}
  if(fn==='fail_integration_run')return {data:'retry_scheduled',error:null}
  return {data:null,error:{message:'actor_not_authorized: secret detail token=abcdefg12345'}}}}
 const repo=new SupabaseRunRepository(client)
 const c=await repo.claim({organizationId:'o',bindingId:'b',adapterKey:'local/fake',capability:'status',fingerprint:'f'.repeat(64),actorUserId:'u',maxAttempts:3,leaseSeconds:300,request:{a:1},correlationId:'c',now:new Date(T0)})
 assert.equal(c.claimToken,'t1');assert.equal(calls[0].fn,'claim_integration_run');assert.equal(calls[0].args.p_adapter_key,'local/fake');assert.equal(calls[0].args.p_now,new Date(T0).toISOString())
 assert.equal(await repo.complete({organizationId:'o',runId:'r1',claimToken:'t1',externalRequestId:'e',artifacts:[{kind:'response_metadata',payload:{},sha256:'s'}],now:new Date(T0)}),'succeeded')
 assert.equal(await repo.fail({organizationId:'o',runId:'r1',claimToken:'t1',code:'x',message:'m',retryable:true,backoffSeconds:30,now:new Date(T0)}),'retry_scheduled')
 await assert.rejects(()=>repo.cancel({organizationId:'o',runId:'r1',actorUserId:'u'}),(e:RepositoryError)=>e.code==='actor_not_authorized'&&!e.message.includes('abcdefg12345'))
 const bad=new SupabaseRunRepository({rpc:async()=>({data:'weird',error:null})})
 await assert.rejects(()=>bad.complete({organizationId:'o',runId:'r',claimToken:'t',externalRequestId:null,artifacts:[],now:new Date(T0)}),(e:RepositoryError)=>e.code==='complete_response_invalid')
})

// ---------- redaction ----------
test('redaction: keys, bearer, JWT, provider keys, URL credentials, key=value, tax ids, bank keys',()=>{
 const jwt='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcd1234'
 const r=redact({Authorization:'Bearer abcdefghijklmnop',api_key:'x',conta:'12345-6',agencia:'0001',cpf:'123.456.789-01',note:`use ${jwt} and sk_test_abcdef1234 at https://u:pw12345@h.test/p with token=abcdef123456`,nested:[{password:'p'}]}) as Record<string,unknown>
 const s=JSON.stringify(r)
 for(const leak of['abcdefghijklmnop','sk_test_abcdef1234','pw12345','abcdef123456','12345-6','0001',jwt,'123.456.789-01'])assert.equal(s.includes(leak),false,leak)
 assert.equal(r.cpf,'*********01');assert.equal((r.nested as {password:string}[])[0].password,REDACTED)
 assert.equal(maskTaxId('12345678000199'),'************99');assert.equal(maskTaxId('123'),'123')
})

test('redaction is idempotent, bounded and preserves safe data',()=>{
 const x={a:'ok',n:5,b:true,z:null,deep:{t:'Bearer abcdefghijklmnopqrstuvwxyz'}}
 assert.deepEqual(redact(redact(x)),redact(x));assert.equal((redact(x) as typeof x).a,'ok');assert.equal((redact(x) as typeof x).n,5)
 let deep:Record<string,unknown>={v:1};for(let i=0;i<40;i++)deep={d:deep}
 assert.doesNotThrow(()=>JSON.stringify(redact(deep)))
 assert.ok(redactString('x'.repeat(50000)).length<20100)
 assert.equal(redactString('amount 1234.56 for proposal 100'),'amount 1234.56 for proposal 100')
})

test('fingerprint ignores secret rotation but changes with tenant, binding, capability, adapter and payload',()=>{
 const base=requestFingerprint(req({payload:{a:1,token:'one'}}),'local/fake')
 assert.equal(requestFingerprint(req({payload:{a:1,token:'two'}}),'local/fake'),base)
 for(const other of[requestFingerprint(req({organizationId:'o2',payload:{a:1}}),'local/fake'),requestFingerprint(req({bindingId:'b2',payload:{a:1}}),'local/fake'),requestFingerprint(req({capability:'submit',payload:{a:1}}),'local/fake'),requestFingerprint(req({payload:{a:1}}),'x/y'),requestFingerprint(req({payload:{a:2}}),'local/fake')])assert.notEqual(other,base)
 assert.equal(requestFingerprint(req({payload:{b:2,a:1}}),'local/fake'),requestFingerprint(req({payload:{a:1,b:2}}),'local/fake'))
})
