import test from 'node:test'
import assert from 'node:assert/strict'
import { executeRun,InMemoryRunRepository,LocalFakeAdapter,redactSecrets,requestFingerprint,backoffMs,STALE_RUNNING_MS,type ExecutionRequest,type ProviderAdapter,type CredentialProvider } from '../../src/lib/integrations/executor'

const creds:CredentialProvider={get:async()=>undefined}
const req=(over:Partial<ExecutionRequest>={}):ExecutionRequest=>({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'proposal_status',payload:{proposal:'100'},...over})
const run=(repo:InMemoryRunRepository,adapter:ProviderAdapter,nowMs:number,over:Partial<Parameters<typeof executeRun>[0]>={})=>executeRun({repo,adapter,request:req(),credentials:creds,nowMs,...over})

test('idempotent: the same request executes once and replays the stored success',async()=>{
 const repo=new InMemoryRunRepository();const a=new LocalFakeAdapter()
 const first=await run(repo,a,1000);const second=await run(repo,a,2000)
 assert.equal(first.state,'succeeded');assert.equal(second.state,'succeeded')
 assert.equal(second.state==='succeeded'&&second.replayed,true)
 assert.equal(a.calls,1);assert.equal(repo.runs.size,1)
})

test('different tenant or binding never shares a run (tenant-scoped identity)',async()=>{
 const repo=new InMemoryRunRepository();const a=new LocalFakeAdapter()
 await run(repo,a,1);await executeRun({repo,adapter:a,request:req({organizationId:'o2'}),credentials:creds,nowMs:2});await executeRun({repo,adapter:a,request:req({bindingId:'b2'}),credentials:creds,nowMs:3})
 assert.equal(repo.runs.size,3);assert.equal(a.calls,3)
})

test('no double submission while a run is in flight; a crashed (stale) run is taken over and counted as an attempt',async()=>{
 const repo=new InMemoryRunRepository();const a=new LocalFakeAdapter()
 const fp=requestFingerprint(req())
 await repo.create({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'proposal_status',fingerprint:fp,status:'running',attemptCount:1,maxAttempts:3,startedAtMs:1000,nextAttemptAtMs:null,externalRequestId:null,errorCode:null,errorMessage:null,metadata:{}})
 const busy=await run(repo,a,1000+STALE_RUNNING_MS-1)
 assert.equal(busy.state,'in_progress');assert.equal(a.calls,0)
 const recovered=await run(repo,a,1000+STALE_RUNNING_MS)
 assert.equal(recovered.state,'succeeded');assert.equal(a.calls,1)
 assert.equal(recovered.state==='succeeded'&&recovered.run.attemptCount,2)
})

test('retryable failures back off, are not retried early, and stop after maxAttempts',async()=>{
 const repo=new InMemoryRunRepository()
 const a=new LocalFakeAdapter([{ok:false,retryable:true,code:'timeout',message:'x'}])
 const r1=await run(repo,a,0,{maxAttempts:3})
 assert.equal(r1.state,'retry_scheduled')
 assert.equal((await run(repo,a,backoffMs(1)-1,{maxAttempts:3})).state,'retry_scheduled');assert.equal(a.calls,1)
 const r2=await run(repo,a,backoffMs(1),{maxAttempts:3});assert.equal(r2.state,'retry_scheduled');assert.equal(a.calls,2)
 const r3=await run(repo,a,backoffMs(1)+backoffMs(2),{maxAttempts:3});assert.equal(r3.state,'failed');assert.equal(a.calls,3)
 assert.equal((await run(repo,a,1e12,{maxAttempts:3})).state,'failed');assert.equal(a.calls,3)
})

test('non-retryable errors are terminal immediately and never retried',async()=>{
 const repo=new InMemoryRunRepository()
 const a=new LocalFakeAdapter([{ok:false,retryable:false,code:'invalid_payload',message:'bad'}])
 const r=await run(repo,a,0);assert.equal(r.state,'failed');assert.equal(r.state==='failed'&&r.run.errorCode,'terminal:invalid_payload')
 await run(repo,a,1e12);assert.equal(a.calls,1)
})

test('a throwing adapter becomes a retryable failure, never an unhandled crash or a false success',async()=>{
 const repo=new InMemoryRunRepository()
 const boom:ProviderAdapter={key:'local/fake',contractVersion:'1',capabilities:['proposal_status'],external:false,execute:async()=>{throw new Error('socket hang up')}}
 const r=await run(repo,boom,0);assert.equal(r.state,'retry_scheduled');assert.equal(r.state==='retry_scheduled'&&r.run.errorCode,'adapter_exception')
})

test('external providers are blocked unless explicitly allowed; capability and adapter must match',async()=>{
 const repo=new InMemoryRunRepository()
 const ext:ProviderAdapter={key:'acme/api',contractVersion:'1',capabilities:['proposal_submit'],external:true,execute:async()=>({ok:true})}
 const request=req({adapterKey:'acme/api',capability:'proposal_submit'})
 assert.deepEqual(await executeRun({repo,adapter:ext,request,credentials:creds,nowMs:0}),{state:'refused',reason:'external_not_allowed'})
 assert.equal((await executeRun({repo,adapter:ext,request,credentials:creds,nowMs:0,allowExternal:true})).state,'succeeded')
 assert.deepEqual(await executeRun({repo,adapter:new LocalFakeAdapter(),request:req({capability:'nope'}),credentials:creds,nowMs:0}),{state:'refused',reason:'capability_unavailable'})
 assert.deepEqual(await executeRun({repo,adapter:new LocalFakeAdapter(),request:req({adapterKey:'other/x'}),credentials:creds,nowMs:0}),{state:'refused',reason:'adapter_mismatch'})
})

test('Bevicred is DEFERRED: always refused, even when external execution is allowed',async()=>{
 const repo=new InMemoryRunRepository()
 const bevi:ProviderAdapter={key:'bevi/webservice_agente',contractVersion:'1',capabilities:['paid_incentives'],external:true,execute:async()=>{throw new Error('must not run')}}
 const r=await executeRun({repo,adapter:bevi,request:req({adapterKey:'bevi/webservice_agente',capability:'paid_incentives'}),credentials:creds,nowMs:0,allowExternal:true})
 assert.deepEqual(r,{state:'refused',reason:'provider_deferred'});assert.equal(repo.runs.size,0)
})

test('secrets are redacted before anything is persisted and do not fork the idempotency identity',async()=>{
 const repo=new InMemoryRunRepository();const a=new LocalFakeAdapter()
 const withToken=req({payload:{proposal:'100',token:'AAA',nested:{password:'p',keep:1}}})
 const rotated=req({payload:{proposal:'100',token:'BBB',nested:{password:'q',keep:1}}})
 assert.equal(requestFingerprint(withToken),requestFingerprint(rotated))
 await executeRun({repo,adapter:a,request:withToken,credentials:creds,nowMs:0})
 const stored=JSON.stringify([...repo.runs.values()])
 assert.ok(!stored.includes('AAA')&&!stored.includes('"p"')&&stored.includes('[redacted]'))
 assert.deepEqual(redactSecrets({a:[{Authorization:'x'}]}),{a:[{Authorization:'[redacted]'}]})
})

test('error messages are truncated and redacted; artifacts keep evidence metadata only',async()=>{
 const repo=new InMemoryRunRepository()
 const a=new LocalFakeAdapter([{ok:false,retryable:false,code:'x',message:'y'.repeat(2000)}])
 const r=await run(repo,a,0);assert.ok(r.state==='failed'&&(r.run.errorMessage??'').length<=500)
 const ok=new LocalFakeAdapter([{ok:true,artifacts:[{kind:'response_metadata',payload:{status:200,token:'zzz'}}]}])
 const r2=await executeRun({repo:new InMemoryRunRepository(),adapter:ok,request:req(),credentials:creds,nowMs:0})
 assert.ok(!JSON.stringify(r2).includes('zzz'))
})
