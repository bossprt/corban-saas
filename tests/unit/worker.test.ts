import test from 'node:test'
import assert from 'node:assert/strict'
import { authorizeWorkerRequest, localProvidersAllowed, resolveProvider, runDispatchCycle, MAX_CYCLE_ITEMS, type WorkerDeps } from '../../src/lib/integrations/worker'
import { requestFingerprint, backoffSeconds } from '../../src/lib/integrations/executor'
import { InMemoryRunRepository, RepositoryError } from '../../src/lib/integrations/repository'
import { BEVI_MANIFEST } from '../../src/lib/integrations/registry'
import { FAKE_MANIFEST, ScriptedProvider, type FakeStep } from '../../src/lib/integrations/fake-provider'
import { capabilityNames, type CredentialProvider } from '../../src/lib/integrations/contract'
import { MemoryLogger } from '../../src/lib/integrations/observability'
import { computeRunMetrics } from '../../src/lib/integrations/metrics'
import { allowedActions, runPhase } from '../../src/lib/integrations/view-state'

const creds:CredentialProvider={get:async()=>undefined}
const ENV={NODE_ENV:'test',CORBAN_ALLOW_LOCAL_PROVIDERS:'1'}
const T0=Date.parse('2026-09-22T10:00:00Z')
const at=(ms:number)=>()=>new Date(T0+ms)

const members:Record<string,Record<string,string>>={o1:{sup:'supervisor',mgr:'manager',agt:'agent',rev:'revoked'},o2:{u2:'admin'}}
const bindings:Record<string,Record<string,{adapterKey:string;capabilities:string[]}>>={o1:{b1:{adapterKey:'local/fake',capabilities:capabilityNames(FAKE_MANIFEST)}},o2:{b2:{adapterKey:'local/fake',capabilities:capabilityNames(FAKE_MANIFEST)}}}
const mkRepo=()=>new InMemoryRunRepository({isMember:(o,u,roles)=>roles.includes(members[o]?.[u]??''),binding:(o,b)=>bindings[o]?.[b]??null})
const enq=(repo:InMemoryRunRepository,payload:Record<string,unknown>={ref:'p1'},over:{org?:string;binding?:string;actor?:string}={})=>{
 const organizationId=over.org??'o1',bindingId=over.binding??'b1'
 return repo.enqueue({organizationId,bindingId,adapterKey:'local/fake',capability:'status',fingerprint:requestFingerprint({organizationId,bindingId,capability:'status',payload},'local/fake'),actorUserId:over.actor??'sup',maxAttempts:3,request:payload,correlationId:'corr-w'})
}
const deps=(repo:InMemoryRunRepository,p:ScriptedProvider,ms:number,over:Partial<WorkerDeps>={}):WorkerDeps=>({repo,factories:{'local/fake':()=>p},env:ENV,credentials:creds,now:at(ms),timeoutMs:200,...over})
const prov=(...s:FakeStep[])=>new ScriptedProvider(s.length?s:[{kind:'success'}])
const only=(repo:InMemoryRunRepository)=>[...repo.runs.values()][0]

test('queued run -> worker cycle -> provider -> evidence -> succeeded; nothing left to do afterwards',async()=>{
 const repo=mkRepo();const p=prov({kind:'success',externalRequestId:'ext-1'});await enq(repo)
 const s=await runDispatchCycle(deps(repo,p,0))
 assert.equal(s.succeeded,1);assert.equal(only(repo).status,'succeeded');assert.equal(only(repo).artifacts.length,1)
 const again=await runDispatchCycle(deps(repo,p,1000));assert.equal(again.examined,0);assert.equal(p.calls.length,1)
})

test('fake/local provider is impossible to select in production or without the explicit flag',async()=>{
 const f={'local/fake':()=>prov()}
 assert.ok(resolveProvider('local/fake',f,ENV))
 assert.equal(resolveProvider('local/fake',f,{NODE_ENV:'production',CORBAN_ALLOW_LOCAL_PROVIDERS:'1'}),null)
 assert.equal(resolveProvider('local/fake',f,{NODE_ENV:'test'}),null)
 assert.equal(resolveProvider('local/fake',f,{NODE_ENV:'development',CORBAN_ALLOW_LOCAL_PROVIDERS:'true'}),null)
 assert.equal(localProvidersAllowed({NODE_ENV:'production',CORBAN_ALLOW_LOCAL_PROVIDERS:'1'}),false)
 const repo=mkRepo();const p=prov();await enq(repo)
 const s=await runDispatchCycle(deps(repo,p,0,{env:{NODE_ENV:'production',CORBAN_ALLOW_LOCAL_PROVIDERS:'1'}}))
 assert.equal(s.examined,0);assert.equal(p.calls.length,0);assert.equal(only(repo).status,'queued')
})

test('registry is the only source of providers: unknown, deferred, unregistered, or manifest-swapped adapters are not resolved',()=>{
 assert.equal(resolveProvider('nope/x',{'nope/x':()=>prov()},ENV),null)
 assert.equal(resolveProvider('bevi/webservice_agente',{'bevi/webservice_agente':()=>new ScriptedProvider([{kind:'success'}],BEVI_MANIFEST)},ENV),null)
 assert.equal(resolveProvider('2tech/busca_contrato_file',{'2tech/busca_contrato_file':()=>prov()},ENV),null)
 assert.equal(resolveProvider('local/fake',{},ENV),null)
 assert.equal(resolveProvider('local/fake',{'local/fake':()=>new ScriptedProvider([{kind:'success'}],{...FAKE_MANIFEST,external:true})},ENV),null)
 assert.equal(resolveProvider('local/fake',{'local/fake':()=>new ScriptedProvider([{kind:'success'}],{...FAKE_MANIFEST,adapterKey:'other/x'})},ENV),null)
 assert.equal(resolveProvider('toString',{},ENV),null)
})

test('worker A claims, worker B cannot execute while the lease is valid; after expiry B takes over and the old worker is fenced',async()=>{
 const repo=mkRepo();const {runId}=await enq(repo);const run=only(repo)
 const a=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:run.fingerprint,actorUserId:'sup',maxAttempts:3,leaseSeconds:60,request:{ref:'p1'},correlationId:'A',now:new Date(T0)})
 const pB=prov({kind:'success',externalRequestId:'ext-B'})
 const during=await runDispatchCycle(deps(repo,pB,30_000));assert.equal(during.examined,0);assert.equal(pB.calls.length,0)
 const after=await runDispatchCycle(deps(repo,pB,61_000,{leaseSeconds:60}));assert.equal(after.succeeded,1);assert.equal(only(repo).attemptCount,2)
 const late=await repo.complete({organizationId:'o1',runId,claimToken:a.claimToken!,externalRequestId:'ext-A',artifacts:[{kind:'response_metadata',payload:{},sha256:'x'}],now:new Date(T0+120_000)})
 assert.equal(late,'conflicting_duplicate');assert.equal(only(repo).externalRequestId,'ext-B')
})

test('timeout then retry: not eligible before backoff, executes after it, same run, attempts counted',async()=>{
 const repo=mkRepo();const p=prov({kind:'timeout'},{kind:'success'});const {runId}=await enq(repo)
 const c1=await runDispatchCycle(deps(repo,p,0,{timeoutMs:20}));assert.equal(c1.retryScheduled,1);assert.equal(only(repo).errorCode,'timeout')
 assert.equal((await runDispatchCycle(deps(repo,p,backoffSeconds(1)*1000-1000,{timeoutMs:20}))).examined,0)
 const c2=await runDispatchCycle(deps(repo,p,backoffSeconds(1)*1000,{timeoutMs:20}));assert.equal(c2.succeeded,1)
 assert.equal(repo.runs.size,1);assert.equal(only(repo).id,runId);assert.equal(only(repo).attemptCount,2)
})

test('transient x3 exhausts attempts, becomes terminal and is never dispatched again',async()=>{
 const repo=mkRepo();const p=prov({kind:'transient'});await enq(repo);let t=0
 for(let i=0;i<5;i++){await runDispatchCycle(deps(repo,p,t));t+=backoffSeconds(i+1)*1000+1}
 assert.equal(p.calls.length,3);assert.equal(only(repo).status,'failed');assert.equal(only(repo).terminal,true)
 assert.equal((await runDispatchCycle(deps(repo,p,t+3_600_000))).examined,0)
})

test('malformed response and provider throw are handled; malformed is terminal',async()=>{
 const repo=mkRepo();await enq(repo);const p=prov({kind:'malformed',shape:'no_response_evidence'})
 const s=await runDispatchCycle(deps(repo,p,0));assert.equal(s.failed,1);assert.equal(only(repo).errorCode,'terminal:malformed_response')
 const repo2=mkRepo();await enq(repo2);const s2=await runDispatchCycle(deps(repo2,prov({kind:'throws',message:'boom token=abcdef123456'}),0))
 assert.equal(s2.retryScheduled,1);assert.equal(String(only(repo2).errorMessage).includes('abcdef123456'),false)
})

test('RETRY (same run) vs REEXECUTION (new run with lineage): parent history untouched, idempotent, terminal parents only, manager+ only',async()=>{
 const repo=mkRepo();const p=prov({kind:'permanent',code:'rejected'},{kind:'success',externalRequestId:'ext-new'});const {runId}=await enq(repo)
 await runDispatchCycle(deps(repo,p,0));const parent=only(repo);assert.equal(parent.terminal,true)
 const snapshot=JSON.stringify(parent)
 const args={organizationId:'o1',parentRunId:runId,reason:'operator fixed the payload issue',correlationId:'ui-1'}
 await assert.rejects(()=>repo.reexecute({...args,actorUserId:'sup'}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 await assert.rejects(()=>repo.reexecute({...args,actorUserId:'agt'}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 await assert.rejects(()=>repo.reexecute({...args,actorUserId:'rev'}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 await assert.rejects(()=>repo.reexecute({...args,reason:'short',actorUserId:'mgr'}),(e:RepositoryError)=>e.code==='reexecution_reason_length_invalid')
 await assert.rejects(()=>repo.reexecute({...args,organizationId:'o2',actorUserId:'u2'}),(e:RepositoryError)=>e.code==='run_not_found')
 const r1=await repo.reexecute({...args,actorUserId:'mgr'});const r2=await repo.reexecute({...args,actorUserId:'mgr'})
 assert.equal(r1.created,true);assert.equal(r2.created,false);assert.equal(r1.runId,r2.runId);assert.notEqual(r1.fingerprint,parent.fingerprint)
 assert.equal(JSON.stringify(repo.runs.get(runId)),snapshot,'parent must be byte-identical')
 assert.equal(repo.runs.get(r1.runId)!.parentRunId,runId);assert.equal(repo.runs.get(r1.runId)!.attemptCount,0)
 const s=await runDispatchCycle(deps(repo,p,10_000));assert.equal(s.succeeded,1);assert.equal(repo.runs.get(r1.runId)!.status,'succeeded');assert.equal(repo.runs.get(runId)!.status,'failed')
 assert.equal(p.calls[1].call.idempotencyKey,r1.fingerprint,'the provider sees a NEW idempotency key for a NEW execution')
})

test('a succeeded or still-retryable run is not re-executable (would duplicate the effect / bypass governed retry)',async()=>{
 const repo=mkRepo();const {runId}=await enq(repo);await runDispatchCycle(deps(repo,prov(),0))
 await assert.rejects(()=>repo.reexecute({organizationId:'o1',parentRunId:runId,actorUserId:'mgr',reason:'try to duplicate success',correlationId:'c'}),(e:RepositoryError)=>e.code==='parent_not_reexecutable')
 const repo2=mkRepo();const {runId:r2}=await enq(repo2);await runDispatchCycle(deps(repo2,prov({kind:'transient'}),0))
 await assert.rejects(()=>repo2.reexecute({organizationId:'o1',parentRunId:r2,actorUserId:'mgr',reason:'skip the backoff please',correlationId:'c'}),(e:RepositoryError)=>e.code==='parent_not_reexecutable')
})

test('cancel: cancelled run is never dispatched or resumed, is auditable, and can only be superseded by a re-execution',async()=>{
 const repo=mkRepo();const p=prov({kind:'transient'},{kind:'success'});const {runId}=await enq(repo)
 await runDispatchCycle(deps(repo,p,0))
 await assert.rejects(()=>repo.cancel({organizationId:'o1',runId,actorUserId:'sup'}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 await assert.rejects(()=>repo.cancel({organizationId:'o2',runId,actorUserId:'u2'}),(e:RepositoryError)=>e.code==='run_not_found')
 assert.equal(await repo.cancel({organizationId:'o1',runId,actorUserId:'mgr'}),'cancelled')
 assert.equal((await runDispatchCycle(deps(repo,p,3_600_000))).examined,0);assert.equal(only(repo).status,'cancelled');assert.equal(only(repo).attemptCount,1)
 await assert.rejects(()=>repo.cancel({organizationId:'o1',runId,actorUserId:'mgr'}),(e:RepositoryError)=>e.code==='illegal_integration_run_transition')
 const child=await repo.reexecute({organizationId:'o1',parentRunId:runId,actorUserId:'mgr',reason:'cancelled by mistake, run again',correlationId:'c'})
 assert.equal(child.created,true);assert.equal(only(repo).status,'cancelled')
})

test('membership revoked between enqueue and dispatch: that run errors, the cycle continues with other work',async()=>{
 const repo=mkRepo();await enq(repo,{ref:'a'},{actor:'sup'});await enq(repo,{ref:'b'},{actor:'mgr'})
 members.o1.sup='revoked'
 try{
  const s=await runDispatchCycle(deps(repo,prov(),0))
  assert.equal(s.errors,1);assert.equal(s.succeeded,1);assert.ok(s.runs.some(r=>r.state==='error:actor_not_authorized'))
 }finally{members.o1.sup='supervisor'}
})

test('tenants stay apart: foreign binding refused at enqueue, identical payload in two tenants = two runs, each executed under its own tenant',async()=>{
 const repo=mkRepo()
 await assert.rejects(()=>enq(repo,{ref:'x'},{org:'o1',binding:'b2'}),(e:RepositoryError)=>e.code==='binding_not_found')
 await assert.rejects(()=>enq(repo,{ref:'x'},{org:'o2',binding:'b1',actor:'u2'}),(e:RepositoryError)=>e.code==='binding_not_found')
 await assert.rejects(()=>enq(repo,{ref:'x'},{org:'o1',actor:'u2'}),(e:RepositoryError)=>e.code==='actor_not_authorized')
 await enq(repo,{ref:'same'});await enq(repo,{ref:'same'},{org:'o2',binding:'b2',actor:'u2'})
 const p=prov();const s=await runDispatchCycle(deps(repo,p,0))
 assert.equal(s.succeeded,2);assert.deepEqual(new Set([...repo.runs.values()].map(r=>r.organizationId)),new Set(['o1','o2']))
 assert.equal(new Set([...repo.runs.values()].map(r=>r.fingerprint)).size,2)
})

test('enqueue is idempotent (duplicate request creates no second run and no second provider call)',async()=>{
 const repo=mkRepo();const a=await enq(repo);const b=await enq(repo)
 assert.equal(a.created,true);assert.equal(b.created,false);assert.equal(a.runId,b.runId)
 const p=prov();await runDispatchCycle(deps(repo,p,0));assert.equal(p.calls.length,1)
})

test('a provider claiming "paid" is only run evidence: the artifact is stored, the run succeeds, and the worker touches nothing else',async()=>{
 const repo=mkRepo();await enq(repo)
 const paid=new ScriptedProvider([{kind:'success'}]);paid.execute=async()=>({ok:true,externalRequestId:'ext-paid',artifacts:[{kind:'response_metadata',payload:{status:'paid',commissionPaid:500}}]})
 const s=await runDispatchCycle(deps(repo,paid,0));assert.equal(s.succeeded,1)
 assert.deepEqual(Object.keys(repo).filter(k=>['proposals','ledger','financialEvents'].includes(k)),[])
 assert.equal((only(repo).artifacts[0].payload as {status:string}).status,'paid')
})

test('cycle is bounded',async()=>{
 const repo=mkRepo();for(let i=0;i<40;i++)await enq(repo,{ref:`r${i}`})
 const s=await runDispatchCycle(deps(repo,prov(),0,{limit:1000}));assert.equal(s.examined,MAX_CYCLE_ITEMS);assert.equal(s.succeeded,MAX_CYCLE_ITEMS)
 const s2=await runDispatchCycle(deps(repo,prov(),0,{limit:0}));assert.equal(s2.examined,1)
})

test('onlyRunId restricts the pass to one run (governed "Nova tentativa")',async()=>{
 const repo=mkRepo();const a=await enq(repo,{ref:'a'});await enq(repo,{ref:'b'})
 const p=prov();const s=await runDispatchCycle(deps(repo,p,0,{onlyRunId:a.runId}))
 assert.equal(s.examined,1);assert.equal(repo.runs.get(a.runId)!.status,'succeeded');assert.equal([...repo.runs.values()].filter(r=>r.status==='queued').length,1)
})

test('worker logs are sanitized events with correlation, provider, adapter, attempt, duration',async()=>{
 const repo=mkRepo();await enq(repo,{ref:'p',password:'hunter2'});const logger=new MemoryLogger()
 await runDispatchCycle(deps(repo,prov({kind:'throws',message:'Authorization: Bearer abcdefghijklmnop'}),0,{logger}))
 const dump=JSON.stringify(logger.events)
 assert.equal(dump.includes('hunter2'),false);assert.equal(dump.includes('abcdefghijklmnop'),false)
 assert.ok(logger.events.every(e=>e.correlationId==='corr-w'&&e.adapter==='local/fake'&&e.provider==='local'))
 const m=computeRunMetrics(logger.events);assert.equal(m.claimed,1);assert.equal(m.retryScheduled,1);assert.equal(m.successRate,null);assert.equal(typeof m.latencyP50Ms,'number')
})

test('metrics: success rate, retry rate, takeovers, terminal failures, latency percentiles',()=>{
 const m=computeRunMetrics([
  {event:'run_claimed',outcome:'claimed'},{event:'run_claimed',outcome:'takeover'},{event:'run_claimed',outcome:'claimed'},{event:'run_claimed',outcome:'claimed'},
  {event:'run_succeeded'},{event:'run_succeeded'},{event:'run_failed'},{event:'run_retry_scheduled'},{event:'run_lease_lost'},
  {event:'provider_called',durationMs:10},{event:'provider_called',durationMs:30},{event:'provider_called',durationMs:20},{event:'provider_called',durationMs:100}])
 assert.equal(m.claimed,4);assert.equal(m.leaseTakeovers,1);assert.equal(m.leaseLost,1);assert.equal(m.failedTerminal,1)
 assert.ok(Math.abs((m.successRate??0)-2/3)<1e-9);assert.equal(m.retryRate,0.25);assert.equal(m.latencyP50Ms,20);assert.equal(m.latencyP95Ms,100)
 assert.equal(computeRunMetrics([]).successRate,null)
})

test('dispatch trigger authorization: disabled without a strong secret, constant-time compare, bearer only',()=>{
 const secret='s'.repeat(32)
 assert.equal(authorizeWorkerRequest(`Bearer ${secret}`,undefined),'disabled')
 assert.equal(authorizeWorkerRequest(`Bearer ${secret}`,'short'),'disabled')
 assert.equal(authorizeWorkerRequest(null,secret),'forbidden')
 assert.equal(authorizeWorkerRequest(secret,secret),'forbidden')
 assert.equal(authorizeWorkerRequest(`Bearer ${'x'.repeat(32)}`,secret),'forbidden')
 assert.equal(authorizeWorkerRequest(`Bearer ${secret}x`,secret),'forbidden')
 assert.equal(authorizeWorkerRequest(`Bearer ${secret}`,secret),'ok')
})

test('UI action matrix: retry supervisor+, cancel/re-execute manager+; terminal failure only offers re-execution; succeeded offers nothing',()=>{
 const q={status:'queued' as const,terminal:false,attempt_count:0,max_attempts:3}
 const retry={status:'failed' as const,terminal:false,attempt_count:1,max_attempts:3}
 const term={status:'failed' as const,terminal:true,attempt_count:1,max_attempts:3}
 const ok={status:'succeeded' as const,terminal:false,attempt_count:1,max_attempts:3}
 const canc={status:'cancelled' as const,terminal:false,attempt_count:1,max_attempts:3}
 assert.deepEqual(allowedActions('agent',q),{retry:false,cancel:false,reexecute:false})
 assert.deepEqual(allowedActions('supervisor',retry),{retry:true,cancel:false,reexecute:false})
 assert.deepEqual(allowedActions('manager',retry),{retry:true,cancel:true,reexecute:false})
 assert.deepEqual(allowedActions('admin',term),{retry:false,cancel:false,reexecute:true})
 assert.deepEqual(allowedActions('supervisor',term),{retry:false,cancel:false,reexecute:false})
 assert.deepEqual(allowedActions('admin',ok),{retry:false,cancel:false,reexecute:false})
 assert.deepEqual(allowedActions('manager',canc),{retry:false,cancel:false,reexecute:true})
 assert.deepEqual(allowedActions(null,q),{retry:false,cancel:false,reexecute:false})
 assert.equal(runPhase(q),'queued')
})

test('redaction regression: an already-redacted "[redacted]" value is not a leak, real secrets in every shape are',async()=>{
 const repo=mkRepo();await enq(repo,{ref:'r',token:'[redacted]',headers:{Authorization:'Bearer abcdefghijklmnop',Cookie:'sid=1','Set-Cookie':'x=y'},list:[{apikey:'k'},{Client_Secret:'s'}],refresh_token:'r',access_token:'a',password:'p',long:'x'.repeat(40000)})
 const s=await runDispatchCycle(deps(repo,prov({kind:'leaky'}),0));assert.equal(s.succeeded,1)
 const dump=JSON.stringify([...repo.runs.values()])
 for(const leak of['abcdefghijklmnop','sid=1','x=y','hunter2pass','sk_live_abcdef123456'])assert.equal(dump.includes(leak),false,leak)
 assert.ok(dump.length<250_000)
})
