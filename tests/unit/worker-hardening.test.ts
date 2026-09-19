import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { authorizeWorkerRequest, handleDispatchRequest, localProvidersAllowed, resolveProvider, runDispatchCycle, type WorkerDeps, type CycleSummary } from '../../src/lib/integrations/worker'
import { requestFingerprint, backoffSeconds } from '../../src/lib/integrations/executor'
import { InMemoryRunRepository, RepositoryError, SupabaseRunRepository } from '../../src/lib/integrations/repository'
import { FAKE_MANIFEST, ScriptedProvider, type FakeStep } from '../../src/lib/integrations/fake-provider'
import { capabilityNames, type CredentialProvider } from '../../src/lib/integrations/contract'
import { classifyTransitionError, OPERATIONAL_MESSAGES, isOperationalErrorCode } from '../../src/lib/operational'
import { classifyRunActionError, lineageOf, RUN_ERROR_MESSAGES } from '../../src/lib/integrations/view-state'

const creds:CredentialProvider={get:async()=>undefined}
const ENV={NODE_ENV:'test',CORBAN_ALLOW_LOCAL_PROVIDERS:'1'}
const T0=Date.parse('2026-09-23T10:00:00Z')
const at=(ms:number)=>()=>new Date(T0+ms)
const ROOT=process.cwd()

// ============ A. architecture: the service role and the worker never reach the browser ============
const walk=(dir:string,out:string[]=[])=>{for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);if(e.isDirectory())walk(p,out);else if(/\.(ts|tsx)$/.test(e.name))out.push(p)}return out}
const srcFiles=walk(path.join(ROOT,'src'))
const rel=(f:string)=>path.relative(ROOT,f).split(path.sep).join('/')
const isClient=(t:string)=>/^\s*(?:\/\/[^\n]*\n|\/\*[\s\S]*?\*\/\s*)*['"]use client['"]/.test(t)
const importsOf=(t:string)=>[...t.matchAll(/(?:import|export)[^'"]*?from\s*['"]([^'"]+)['"]|import\s*\(\s*['"]([^'"]+)['"]\s*\)|import\s*['"]([^'"]+)['"]/g)].map(m=>m[1]??m[2]??m[3])

test('architecture: no Client Component imports the admin client, the worker, the repository or the executor',()=>{
 const forbidden=/supabaseAdmin|worker\.server|integrations\/(repository|worker|executor|fake-provider)|server-only/
 const offenders:string[]=[]
 let clients=0
 for(const f of srcFiles){const t=fs.readFileSync(f,'utf8');if(!isClient(t))continue;clients++;for(const i of importsOf(t))if(forbidden.test(i))offenders.push(`${rel(f)} -> ${i}`)}
 assert.deepEqual(offenders,[]);assert.ok(clients>=0)
})

test('architecture: the service role key is read in exactly one module and that module is server-only',()=>{
 const users=srcFiles.filter(f=>/SUPABASE_SERVICE_ROLE_KEY/.test(fs.readFileSync(f,'utf8'))).map(rel)
 assert.deepEqual(users,['src/lib/supabaseAdmin.ts'])
 assert.match(fs.readFileSync(path.join(ROOT,'src/lib/supabaseAdmin.ts'),'utf8'),/^import 'server-only'/m)
 assert.match(fs.readFileSync(path.join(ROOT,'src/lib/integrations/worker.server.ts'),'utf8'),/^import 'server-only'/m)
 for(const f of srcFiles)assert.equal(/NEXT_PUBLIC_[A-Z_]*(SERVICE|WORKER_SECRET)/.test(fs.readFileSync(f,'utf8')),false,rel(f))
})

test('architecture: only server modules import admin/worker code, and the worker secret is read only by the dispatch route',()=>{
 const importers=srcFiles.filter(f=>importsOf(fs.readFileSync(f,'utf8')).some(i=>/supabaseAdmin|worker\.server/.test(i))).map(rel).sort()
 // admin/organizations authenticates the caller and requires an active platform administrator before touching the admin client
 assert.deepEqual(importers,['src/app/api/admin/organizations/route.ts','src/app/api/integrations/dispatch/route.ts','src/app/app/integracoes/actions.ts','src/lib/integrations/worker.server.ts'])
 for(const f of importers){const t=fs.readFileSync(path.join(ROOT,f),'utf8');assert.equal(isClient(t),false,f)}
 assert.deepEqual(srcFiles.filter(f=>/INTEGRATION_WORKER_SECRET/.test(fs.readFileSync(f,'utf8'))).map(rel),['src/app/api/integrations/dispatch/route.ts'])
 const actions=fs.readFileSync(path.join(ROOT,'src/app/app/integracoes/actions.ts'),'utf8')
 assert.match(actions,/^'use server'/);assert.equal(/\.update\(|\.delete\(|\.insert\(/.test(actions),false)
 const worker=fs.readFileSync(path.join(ROOT,'src/lib/integrations/worker.ts'),'utf8')
 assert.equal(importsOf(worker).some(i=>/^next|supabase|server-only/.test(i)),false)
})

// ============ B. dispatch endpoint ============
const SECRET='S3cr3t-'.repeat(5)
const okRun=async():Promise<CycleSummary>=>({examined:2,succeeded:1,replayed:0,retryScheduled:1,failed:0,inProgress:0,leaseLost:0,refused:0,errors:0,deferred:0,runs:[{runId:'r1',state:'succeeded'},{runId:'r2',state:'retry_scheduled'}]})
const call=(authorization:string|null|undefined,secret:string|undefined|'default'='default',run=okRun)=>handleDispatchRequest({authorization,secret:secret==='default'?SECRET:secret,run})

test('dispatch: disabled without a secret or with a weak one (503), never runs',async()=>{
 let ran=0;const run=async()=>{ran++;return okRun()}
 for(const secret of[undefined,'','short','x'.repeat(23)]){const r=await handleDispatchRequest({authorization:`Bearer ${SECRET}`,secret,run});assert.equal(r.status,503);assert.deepEqual(r.body,{error:'dispatch_disabled'})}
 assert.equal(ran,0)
})

test('dispatch: wrong, empty, malformed and multiple credentials are refused (403) without running',async()=>{
 let ran=0;const run=async()=>{ran++;return okRun()}
 const bad=[null,undefined,'','Bearer','Bearer ','Bearer  ',`Bearer ${SECRET}x`,`Bearer x${SECRET}`,`Bearer ${SECRET.toUpperCase()}`,`Basic ${SECRET}`,SECRET,`Bearer ${SECRET} extra`,`Bearer ${SECRET}, Bearer ${SECRET}`,` Bearer ${SECRET}`,`Bearer ${SECRET} `,`Bearer\t${SECRET}`,`Bearer ${SECRET}\n`,`Token ${SECRET}`,`Bearer a b`,'Bearer '+'a'.repeat(5000)]
 for(const h of bad){const r=await call(h,SECRET,run);assert.equal(r.status,403,String(h));assert.deepEqual(r.body,{error:'forbidden'})}
 assert.equal(ran,0)
})

test('dispatch: the scheme is case-insensitive, the credential exact; success returns counts only',async()=>{
 for(const scheme of['Bearer','bearer','BEARER','bEaReR']){const r=await call(`${scheme} ${SECRET}`);assert.equal(r.status,200);assert.equal(r.body.ok,true);assert.equal(r.body.runs,2);assert.equal(r.body.succeeded,1)}
 assert.equal(authorizeWorkerRequest(`Bearer   ${SECRET}`,SECRET),'ok')  // padding BETWEEN scheme and token is legal; padding around the token is not
})

test('dispatch: secrets, presented credentials, run ids and exception text never appear in any response',async()=>{
 const attempt='Bearer WRONG-CREDENTIAL-1234567890abcdef'
 const bodies=[(await call(attempt)).body,(await call(null)).body,(await handleDispatchRequest({authorization:`Bearer ${SECRET}`,secret:undefined,run:okRun})).body,(await call(`Bearer ${SECRET}`)).body,
  (await call(`Bearer ${SECRET}`,SECRET,async()=>{throw new Error(`boom token=${SECRET} Authorization: Bearer ${SECRET}`)})).body]
 const dump=JSON.stringify(bodies)
 for(const leak of[SECRET,'WRONG-CREDENTIAL','boom','r1','r2'])assert.equal(dump.includes(leak),false,leak)
 assert.deepEqual(bodies[4],{error:'dispatch_failed'})
})

test('dispatch: the route depends on no session and no user data',()=>{
 const route=fs.readFileSync(path.join(ROOT,'src/app/api/integrations/dispatch/route.ts'),'utf8')
 assert.equal(/cookies|createClient|requireAppContext|auth\.getUser/.test(route),false)
 assert.match(route,/export async function POST/);assert.equal(/export async function (GET|PUT|PATCH|DELETE)/.test(route),false)
 assert.match(fs.readFileSync(path.join(ROOT,'src/utils/supabase/middleware.ts'),'utf8'),/'\/api\/integrations\/dispatch'/)
})

// ============ C. production guard for the local/fake provider ============
test('guard matrix: the fake provider resolves ONLY with an allowed NODE_ENV and the exact flag',()=>{
 const f={'local/fake':()=>new ScriptedProvider()}
 const cases:[string|undefined,string|undefined,boolean][]=[
  ['production','1',false],['production',undefined,false],['production','true',false],['production','0',false],['Production','1',false],['production ','1',false],
  ['test',undefined,false],['test','',false],['test','0',false],['test','true',false],['test','1',true],
  ['development','1',true],['development',undefined,false],[undefined,'1',false],['','1',false],['staging','1',false],['preview','1',false]]
 for(const [n,fl,expected] of cases){
  const env={NODE_ENV:n,CORBAN_ALLOW_LOCAL_PROVIDERS:fl}
  assert.equal(localProvidersAllowed(env),expected,`${n}/${fl}`)
  assert.equal(resolveProvider('local/fake',f,env)!==null,expected,`resolve ${n}/${fl}`)
 }
})

test('guard: a worker with only unresolvable adapters does no work at all',async()=>{
 const repo=guarded();await enq(repo)
 const p=new ScriptedProvider()
 for(const env of[{NODE_ENV:'production',CORBAN_ALLOW_LOCAL_PROVIDERS:'1'},{NODE_ENV:'production'},{NODE_ENV:'test'}]){
  const s=await runDispatchCycle({repo,factories:{'local/fake':()=>p},env,credentials:creds,now:at(0)})
  assert.equal(s.examined,0);assert.equal(p.calls.length,0)
 }
 assert.equal([...repo.runs.values()][0].status,'queued')
})

// ============ shared helpers ============
const members:Record<string,Record<string,string>>={o1:{sup:'supervisor',mgr:'manager',agt:'agent'},o2:{u2:'admin'}}
const bindings:Record<string,Record<string,{adapterKey:string;capabilities:string[]}>>={
 o1:{b1:{adapterKey:'local/fake',capabilities:capabilityNames(FAKE_MANIFEST)},b2t:{adapterKey:'2tech/busca_contrato_file',capabilities:['status']}},
 o2:{b2:{adapterKey:'local/fake',capabilities:capabilityNames(FAKE_MANIFEST)}}}
const guarded=()=>new InMemoryRunRepository({isMember:(o,u,roles)=>roles.includes(members[o]?.[u]??''),binding:(o,b)=>bindings[o]?.[b]??null})
const enqAny=(repo:{enqueue:InMemoryRunRepository['enqueue']},payload:Record<string,unknown>,adapterKey='local/fake',bindingId='b1',capability='status',maxAttempts=3)=>{
 const organizationId='o1'
 return repo.enqueue({organizationId,bindingId,adapterKey,capability,fingerprint:requestFingerprint({organizationId,bindingId,capability,payload},adapterKey),actorUserId:'sup',maxAttempts,request:payload,correlationId:'corr-h'})
}
const enq=(repo:InMemoryRunRepository,payload:Record<string,unknown>={ref:'p1'})=>enqAny(repo,payload)
const deps=(repo:WorkerDeps['repo'],p:ScriptedProvider,ms:number,over:Partial<WorkerDeps>={}):WorkerDeps=>({repo,factories:{'local/fake':()=>p},env:ENV,credentials:creds,now:at(ms),timeoutMs:200,...over})
const prov=(...s:FakeStep[])=>new ScriptedProvider(s.length?s:[{kind:'success'}])
const only=(repo:InMemoryRunRepository)=>[...repo.runs.values()][0]

// ============ D. backpressure, ordering, starvation ============
test('backpressure: 0, 1, 25, 26 and 100 eligible runs are bounded per cycle and drain over cycles',async()=>{
 for(const [n,first,cycles] of[[0,0,0],[1,1,1],[25,25,1],[26,25,2],[100,25,4]] as const){
  const repo=guarded();for(let i=0;i<n;i++)await enq(repo,{ref:`r${i}`})
  const p=prov();let done=0;let c=0;let firstCycle=-1
  while(c<10){const s=await runDispatchCycle(deps(repo,p,c*1000,{limit:1000}));if(firstCycle<0)firstCycle=s.examined;done+=s.succeeded;c++;if(s.examined===0)break}
  assert.equal(firstCycle,first,`n=${n}`);assert.equal(done,n,`n=${n}`);assert.equal(c,cycles+1,`n=${n} cycles (the last pass finds nothing left)`)
  assert.equal(p.calls.length,n)
 }
})

test('starvation: runs the worker cannot run never occupy slots (30 unrunnable adapters do not block a runnable run)',async()=>{
 const repo=guarded()
 for(let i=0;i<30;i++)await enqAny(repo,{ref:`t${i}`},'2tech/busca_contrato_file','b2t')
 const good=await enq(repo,{ref:'good'})
 const p=prov();const s=await runDispatchCycle(deps(repo,p,0))
 assert.equal(s.succeeded,1);assert.equal(repo.runs.get(good.runId)!.status,'succeeded');assert.equal(s.refused,0)
 assert.equal([...repo.runs.values()].filter(r=>r.status==='queued').length,30)
})

test('starvation: always-failing work backs off and cannot block newer eligible work; order is by eligibility time',async()=>{
 const repo=guarded();const failing=prov({kind:'transient'})
 for(let i=0;i<40;i++)await enq(repo,{ref:`f${i}`})
 const c1=await runDispatchCycle(deps(repo,failing,0,{limit:25}));assert.equal(c1.retryScheduled,25)
 const fresh=await enq(repo,{ref:'fresh'})
 const ok=prov({kind:'success'})
 const c2=await runDispatchCycle(deps(repo,ok,1000,{limit:25}))
 // remaining 15 never-tried runs + the fresh one are eligible NOW; the 25 in backoff are not
 assert.equal(c2.examined,16);assert.ok(c2.runs.some(r=>r.runId===fresh.runId&&r.state==='succeeded'))
 const c3=await runDispatchCycle(deps(repo,ok,backoffSeconds(1)*1000+1,{limit:25}))
 assert.equal(c3.examined,25);assert.equal(c3.succeeded,25)
 assert.equal([...repo.runs.values()].every(r=>r.status==='succeeded'),true)
})

test('ordering: a retry that became due earlier is served before one that became due later',async()=>{
 const repo=guarded();const a=await enq(repo,{ref:'a'});const b=await enq(repo,{ref:'b'})
 const A=repo.runs.get(a.runId)!,B=repo.runs.get(b.runId)!
 for(const [r,t] of[[B,5],[A,9]] as const){r.status='failed';r.attemptCount=1;r.nextAttemptAt=T0+t*1000}
 const items=await repo.listDispatchable(10,new Date(T0+20_000),['local/fake'])
 assert.deepEqual(items.map(i=>i.runId),[b.runId,a.runId])
})

// ============ E. cancel vs a running worker, fencing ============
test('cancel: a RUNNING run cannot be cancelled (explicit error); the worker completes normally',async()=>{
 const repo=guarded();const {runId}=await enq(repo,{ref:'c'});const p=prov({kind:'delayed',delayMs:40})
 const cycle=runDispatchCycle(deps(repo,p,0));await new Promise(r=>setTimeout(r,10))
 assert.equal(repo.runs.get(runId)!.status,'running')
 await assert.rejects(()=>repo.cancel({organizationId:'o1',runId,actorUserId:'mgr'}),(e:RepositoryError)=>e.code==='illegal_integration_run_transition')
 assert.equal((await cycle).succeeded,1)
})

test('cancel while a retry is scheduled: the previous worker (old token) cannot resurrect it; history is intact',async()=>{
 const repo=guarded();const {runId}=await enq(repo,{ref:'c2'})
 const fp=only(repo).fingerprint
 const w1=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'sup',maxAttempts:3,leaseSeconds:60,request:{},correlationId:'x',now:new Date(T0)})
 await repo.fail({organizationId:'o1',runId,claimToken:w1.claimToken!,code:'timeout',message:'slow',retryable:true,backoffSeconds:30,now:new Date(T0)})
 assert.equal(await repo.cancel({organizationId:'o1',runId,actorUserId:'mgr'}),'cancelled')
 assert.equal(await repo.complete({organizationId:'o1',runId,claimToken:w1.claimToken!,externalRequestId:'late',artifacts:[{kind:'response_metadata',payload:{},sha256:'z'}],now:new Date(T0+5000)}),'lease_lost')
 assert.equal(only(repo).status,'cancelled');assert.equal(only(repo).externalRequestId,null)
 assert.deepEqual(repo.history(runId).map(h=>h.outcome),['retry_scheduled'])
 await assert.rejects(()=>repo.cancel({organizationId:'o1',runId,actorUserId:'mgr'}),(e:RepositoryError)=>e.code==='illegal_integration_run_transition')
})

// ============ F. attempt history survives retry and takeover ============
test('history: every failed attempt and every expired lease is kept; retry never resets it',async()=>{
 const repo=guarded();const {runId}=await enqAny(repo,{ref:'h'},'local/fake','b1','status',6);const p=prov({kind:'transient',code:'unavailable'},{kind:'timeout'},{kind:'success'})
 await runDispatchCycle(deps(repo,p,0,{timeoutMs:20}))
 const fp=only(repo).fingerprint
 await runDispatchCycle(deps(repo,p,backoffSeconds(1)*1000,{timeoutMs:20}))
 assert.deepEqual(repo.history(runId).map(h=>`${h.attempt}:${h.outcome}:${h.code}`),['1:retry_scheduled:unavailable','2:retry_scheduled:timeout'])
 // worker dies on attempt 3, another takes over
 const dead=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'sup',maxAttempts:6,leaseSeconds:60,request:{},correlationId:'x',now:new Date(T0+3_000_000)})
 assert.equal(dead.attemptCount,3)
 await runDispatchCycle(deps(repo,p,3_000_000+61_000))
 const h=repo.history(runId).map(x=>`${x.attempt}:${x.outcome}`)
 assert.deepEqual(h,['1:retry_scheduled','2:retry_scheduled','3:lease_expired'])
 const r=only(repo);assert.equal(r.status,'succeeded');assert.equal(r.fingerprint,fp);assert.equal(r.capability,'status');assert.equal(r.organizationId,'o1')
})

// ============ G. real SupabaseRunRepository + worker over an RPC bridge, and contract vs the SQL ============
type Rec={fn:string;args:Record<string,unknown>}
class MemoryRpc{
 calls:Rec[]=[];rows:Record<string,Record<string,unknown>[]>={}
 constructor(private mem:InMemoryRunRepository){}
 private d=(v:unknown)=>new Date(String(v))
 async rpc(fn:string,a:Record<string,unknown>):Promise<{data:unknown;error:{message:string}|null}>{
  this.calls.push({fn,args:{...a}})
  try{
   switch(fn){
    case'claim_integration_run':{const c=await this.mem.claim({organizationId:a.p_org as string,bindingId:a.p_binding as string,adapterKey:a.p_adapter_key as string,capability:a.p_capability as string,fingerprint:a.p_fingerprint as string,actorUserId:a.p_actor as string,maxAttempts:a.p_max_attempts as number,leaseSeconds:a.p_lease_seconds as number,request:a.p_request as Record<string,unknown>,correlationId:a.p_correlation as string,now:this.d(a.p_now)})
     return {data:[{run_id:c.runId,outcome:c.outcome,claim_token:c.claimToken,attempt_count:c.attemptCount,status:c.status,next_attempt_at:c.nextAttemptAt?.toISOString()??null,external_request_id:c.externalRequestId,error_code:c.errorCode}],error:null}}
    case'complete_integration_run':return {data:await this.mem.complete({organizationId:a.p_org as string,runId:a.p_run as string,claimToken:a.p_token as string,externalRequestId:a.p_external_request_id as string|null,artifacts:a.p_artifacts as never,now:this.d(a.p_now)}),error:null}
    case'fail_integration_run':return {data:await this.mem.fail({organizationId:a.p_org as string,runId:a.p_run as string,claimToken:a.p_token as string,code:a.p_code as string,message:a.p_message as string,retryable:a.p_retryable as boolean,backoffSeconds:a.p_backoff_seconds as number,now:this.d(a.p_now)}),error:null}
    case'cancel_integration_run':return {data:await this.mem.cancel({organizationId:a.p_org as string,runId:a.p_run as string,actorUserId:a.p_actor as string}),error:null}
    case'enqueue_integration_run':{const e=await this.mem.enqueue({organizationId:a.p_org as string,bindingId:a.p_binding as string,adapterKey:a.p_adapter_key as string,capability:a.p_capability as string,fingerprint:a.p_fingerprint as string,actorUserId:a.p_actor as string,maxAttempts:a.p_max_attempts as number,request:a.p_request as Record<string,unknown>,correlationId:a.p_correlation as string});return {data:[{run_id:e.runId,status:e.status,created:e.created}],error:null}}
    case'list_dispatchable_integration_runs':{const l=await this.mem.listDispatchable(a.p_limit as number,this.d(a.p_now),(a.p_adapter_keys as string[]|null)??undefined)
     return {data:l.map(i=>({run_id:i.runId,organization_id:i.organizationId,binding_id:i.bindingId,adapter_key:i.adapterKey,capability:i.capability,fingerprint:i.fingerprint,correlation_id:i.correlationId,status:i.status,attempt_count:i.attemptCount,max_attempts:i.maxAttempts,request:i.request,actor_user_id:i.actorUserId})),error:null}}
    case'create_integration_reexecution':{const r=await this.mem.reexecute({organizationId:a.p_org as string,parentRunId:a.p_parent as string,actorUserId:a.p_actor as string,reason:a.p_reason as string,correlationId:a.p_correlation as string});return {data:[{run_id:r.runId,fingerprint:r.fingerprint,created:r.created}],error:null}}
   }
   return {data:null,error:{message:`unknown_function ${fn}`}}
  }catch(e){if(e instanceof RepositoryError)return {data:null,error:{message:e.code}};throw e}
 }
}
const bridge=()=>{const mem=guarded();const rpc=new MemoryRpc(mem);const repo=new SupabaseRunRepository(rpc as never);return {mem,rpc,repo}}

test('worker over the REAL SupabaseRunRepository: success, delayed, duplicate, timeout, transient, permanent, throw, malformed, leaky',async()=>{
 const scenarios:[string,FakeStep[],string][]=[
  ['success',[{kind:'success',externalRequestId:'e1'}],'succeeded'],['delayed',[{kind:'delayed',delayMs:20}],'succeeded'],['duplicate',[{kind:'duplicate',externalRequestId:'dup'}],'succeeded'],
  ['timeout',[{kind:'timeout'}],'retry_scheduled'],['transient',[{kind:'transient'}],'retry_scheduled'],['throws',[{kind:'throws',message:'boom'}],'retry_scheduled'],
  ['permanent',[{kind:'permanent'}],'failed'],['malformed',[{kind:'malformed',shape:'no_response_evidence'}],'failed'],['leaky',[{kind:'leaky'}],'succeeded']]
 for(const [name,script,expected] of scenarios){
  const {mem,repo}=bridge();await enqAny(repo,{ref:name})
  const s=await runDispatchCycle(deps(repo,new ScriptedProvider(script),0,{timeoutMs:100}))
  assert.equal(s.examined,1,name);assert.equal(s.runs[0].state,expected,name)
  const dump=JSON.stringify([...mem.runs.values()])
  for(const leak of['abcdef0123456789abcdef','sk_live_abcdef123456','hunter2pass','sid=1'])assert.equal(dump.includes(leak),false,`${name}:${leak}`)
 }
})

test('real repository: a duplicate provider answer collapses, replays, and a second worker is fenced',async()=>{
 const {mem,repo}=bridge();const {runId}=await enqAny(repo,{ref:'d'});const p=prov({kind:'success',externalRequestId:'ext-1'})
 const fp=[...mem.runs.values()][0].fingerprint
 const old=await repo.claim({organizationId:'o1',bindingId:'b1',adapterKey:'local/fake',capability:'status',fingerprint:fp,actorUserId:'sup',maxAttempts:3,leaseSeconds:60,request:{},correlationId:'a',now:new Date(T0)})
 const s=await runDispatchCycle(deps(repo,p,61_000,{leaseSeconds:60}));assert.equal(s.succeeded,1)
 assert.equal(await repo.complete({organizationId:'o1',runId,claimToken:old.claimToken!,externalRequestId:'ext-OLD',artifacts:[{kind:'response_metadata',payload:{},sha256:'o'}],now:new Date(T0+70_000)}),'conflicting_duplicate')
 assert.equal(mem.runs.get(runId)!.externalRequestId,'ext-1')
 const again=await runDispatchCycle(deps(repo,p,100_000));assert.equal(again.examined,0)
})

test('real repository: cancel and re-execution through the RPC mapping, lineage and idempotency',async()=>{
 const {mem,repo}=bridge();const {runId}=await enqAny(repo,{ref:'x'});await runDispatchCycle(deps(repo,prov({kind:'permanent'}),0))
 assert.equal(mem.runs.get(runId)!.terminal,true)
 const a=await repo.reexecute({organizationId:'o1',parentRunId:runId,actorUserId:'mgr',reason:'operator corrected the reference',correlationId:'ui'})
 const b=await repo.reexecute({organizationId:'o1',parentRunId:runId,actorUserId:'mgr',reason:'operator corrected the reference',correlationId:'ui'})
 assert.equal(a.created,true);assert.equal(b.created,false);assert.equal(a.runId,b.runId)
 assert.equal((await runDispatchCycle(deps(repo,prov(),10_000))).succeeded,1)
 assert.equal(mem.runs.get(runId)!.status,'failed');assert.equal(mem.runs.get(a.runId)!.status,'succeeded')
 assert.deepEqual([...lineageOf([{id:a.runId,parent_run_id:runId},{id:runId,parent_run_id:null}])],[[runId,a.runId]])
 const {mem:m2,repo:r2}=bridge();const q=await enqAny(r2,{ref:'q'})
 assert.equal(await r2.cancel({organizationId:'o1',runId:q.runId,actorUserId:'mgr'}),'cancelled')
 assert.equal((await runDispatchCycle(deps(r2,prov(),1))).examined,0);assert.equal(m2.runs.get(q.runId)!.status,'cancelled')
})

// Contract: what the TypeScript repository sends / expects must match the LATEST SQL definition of each function (parsed from migrations).
const sqlText=fs.readdirSync(path.join(ROOT,'supabase/migrations')).filter(f=>f.endsWith('.sql')).sort().map(f=>fs.readFileSync(path.join(ROOT,'supabase/migrations',f),'utf8')).join('\n')
function latestSignature(fn:string){
 const re=new RegExp(`create or replace function public\\.${fn}\\(`,'gi');let last=-1;let m:RegExpExecArray|null
 while((m=re.exec(sqlText)))last=m.index+m[0].length
 assert.ok(last>=0,`${fn} not found in migrations`)
 let depth=1,i=last;while(depth>0){const ch=sqlText[i++];if(ch==='(')depth++;else if(ch===')')depth--}
 const params:string[]=[];let cur='',d=0
 for(const ch of sqlText.slice(last,i-1)){if(ch==='(')d++;if(ch===')')d--;if(ch===','&&d===0){params.push(cur);cur=''}else cur+=ch}
 if(cur.trim())params.push(cur)
 const parsed=params.map(p=>({name:p.trim().split(/\s+/)[0],hasDefault:/\sdefault\s/i.test(p)}))
 const after=sqlText.slice(i).split(/\bas\s+\$/i)[0];const rt=/returns table\(([^)]*(?:\([^)]*\)[^)]*)*)\)/i.exec(after)
 const cols=rt?rt[1].split(',').map(c=>c.trim().split(/\s+/)[0]):null
 return {params:parsed,cols}
}
test('contract: every RPC argument the repository sends exists in the SQL signature and every required one is sent',async()=>{
 const {mem,rpc,repo}=bridge();const {runId}=await enqAny(repo,{ref:'k'})
 await runDispatchCycle(deps(repo,prov({kind:'permanent'}),0))
 await repo.reexecute({organizationId:'o1',parentRunId:runId,actorUserId:'mgr',reason:'contract test reexecution',correlationId:'c'})
 await runDispatchCycle(deps(repo,prov(),1000))
 const q=await enqAny(repo,{ref:'k2'});await repo.cancel({organizationId:'o1',runId:q.runId,actorUserId:'mgr'})
 void mem
 const seen=new Set(rpc.calls.map(c=>c.fn))
 for(const fn of['claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run','enqueue_integration_run','list_dispatchable_integration_runs','create_integration_reexecution'])assert.ok(seen.has(fn),`bridge did not exercise ${fn}`)
 for(const c of rpc.calls){
  const sig=latestSignature(c.fn);const names=sig.params.map(p=>p.name)
  for(const k of Object.keys(c.args))assert.ok(names.includes(k),`${c.fn}: sends unknown argument ${k}`)
  for(const p of sig.params.filter(p=>!p.hasDefault))assert.ok(p.name in c.args,`${c.fn}: required argument ${p.name} not sent`)
 }
})
test('contract: the row shapes the mapper reads are exactly the columns the SQL functions return',async()=>{
 const expected:Record<string,string[]>={
  claim_integration_run:['run_id','outcome','claim_token','attempt_count','status','next_attempt_at','external_request_id','error_code'],
  enqueue_integration_run:['run_id','status','created'],
  create_integration_reexecution:['run_id','fingerprint','created'],
  list_dispatchable_integration_runs:['run_id','organization_id','binding_id','adapter_key','capability','fingerprint','correlation_id','status','attempt_count','max_attempts','request','actor_user_id']}
 for(const [fn,cols] of Object.entries(expected))assert.deepEqual(latestSignature(fn).cols,cols,fn)
 for(const fn of['complete_integration_run','fail_integration_run','cancel_integration_run'])assert.equal(latestSignature(fn).cols,null,fn)
 // the mapper reads keys by these names
 const {rpc,repo}=bridge();await enqAny(repo,{ref:'m'})
 const rows=(await rpc.rpc('list_dispatchable_integration_runs',{p_limit:5,p_now:new Date(T0).toISOString(),p_adapter_keys:null})).data as Record<string,unknown>[]
 assert.deepEqual(Object.keys(rows[0]),expected.list_dispatchable_integration_runs)
})

test('contract: the migrations keep every worker RPC service_role-only and free of SECURITY DEFINER',()=>{
 for(const fn of['claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run','enqueue_integration_run','list_dispatchable_integration_runs','create_integration_reexecution']){
  const idx=[...sqlText.matchAll(new RegExp(`create or replace function public\\.${fn}\\(`,'gi'))].map(m=>m.index!)
  const body=sqlText.slice(idx[idx.length-1],idx[idx.length-1]+3000).split(/\n(?:create|revoke|grant|drop)\s/i)[0]
  assert.equal(/security definer/i.test(body),false,fn)
 }
 assert.match(sqlText,/grant execute on function public\.claim_integration_run[^;]*to service_role/i)
 assert.equal(/grant execute on function public\.(claim|complete|fail|cancel|enqueue|list_dispatchable|create_integration)[^;]*to (authenticated|anon|public)/i.test(sqlText),false)
})

// ============ H. operator feedback ============
test('operational feedback: each RPC rule maps to a distinct operator message; nothing raw leaks',()=>{
 const cases:[string,string][]=[['invalid_operational_state_transition','invalid_transition'],['operational_decision_requires_privileged_role','forbidden'],['active_membership_required','forbidden'],['operational_case_not_found_or_forbidden','case_unavailable'],['paid_requires_confirmed_financial_source','paid_requires_source'],['target_operational_stage_not_configured','stage_not_configured'],['permission denied for table x','unexpected'],['','unexpected']]
 for(const [msg,code] of cases){const c=classifyTransitionError(msg);assert.equal(c,code,msg);assert.ok(isOperationalErrorCode(c));assert.ok(OPERATIONAL_MESSAGES[c].length>10)}
 assert.equal(new Set(Object.values(OPERATIONAL_MESSAGES)).size,Object.keys(OPERATIONAL_MESSAGES).length)
 assert.equal(isOperationalErrorCode('<script>'),false);assert.equal(classifyTransitionError(null),'unexpected')
})
test('run action feedback: repository codes map to stable operator codes',()=>{
 const m:[string|null,string][]=[['actor_not_authorized','forbidden'],['run_not_found','run_not_found'],['parent_not_reexecutable','not_reexecutable'],['illegal_integration_run_transition','illegal_transition'],['reexecution_reason_length_invalid','reason_invalid'],['weird',"unexpected"],[null,'unexpected']]
 for(const [c,o] of m)assert.equal(classifyRunActionError(c),o)
 assert.ok(Object.values(RUN_ERROR_MESSAGES).every(x=>!/[a-z]+_[a-z]+_/.test(x)))
})

// ============ I. wall-clock budget (serverless-safe pass) ============
test('budget: a pass stops starting runs when the remaining time cannot cover a provider timeout; the rest stays for the next pass',async()=>{
 const repo=guarded();for(let i=0;i<10;i++)await enq(repo,{ref:`b${i}`})
 let t=0;const p=prov({kind:'success'})
 const s=await runDispatchCycle({...deps(repo,p,0,{limit:10,timeoutMs:100}),budgetMs:5_000,clockMs:()=>{t+=1_000;return t}})
 assert.ok(s.examined>=1&&s.examined<10);assert.equal(s.deferred,10-s.examined);assert.equal(s.succeeded,s.examined)
 assert.equal([...repo.runs.values()].filter(r=>r.status==='queued').length,10-s.examined)
 const next=await runDispatchCycle(deps(repo,p,1000,{limit:25}));assert.equal(next.succeeded,10-s.examined)
 const noBudget=await runDispatchCycle(deps(guarded(),prov(),0));assert.equal(noBudget.deferred,0)
})

// ============ J. code deployed before its migration ============
test('compat: with the legacy 2-argument dispatch function (migration not applied) the repository falls back and filters client-side',async()=>{
 const rows=[{run_id:'r1',organization_id:'o1',binding_id:'b1',adapter_key:'local/fake',capability:'status',fingerprint:'f'.repeat(64),correlation_id:'c',status:'queued',attempt_count:0,max_attempts:3,request:{},actor_user_id:'u'},{run_id:'r2',organization_id:'o1',binding_id:'b1',adapter_key:'2tech/busca_contrato_file',capability:'status',fingerprint:'e'.repeat(64),correlation_id:'c',status:'queued',attempt_count:0,max_attempts:3,request:{},actor_user_id:'u'}]
 const calls:Record<string,unknown>[]=[]
 const client={rpc:async(_fn:string,args:Record<string,unknown>)=>{calls.push(args);return 'p_adapter_keys' in args?{data:null,error:{message:'Could not find the function public.list_dispatchable_integration_runs(p_adapter_keys, p_limit, p_now) in the schema cache',code:'PGRST202'}}:{data:rows,error:null}}}
 const items=await new SupabaseRunRepository(client as never).listDispatchable(10,new Date(T0),['local/fake'])
 assert.deepEqual(items.map(i=>i.runId),['r1']);assert.equal(calls.length,2);assert.equal('p_adapter_keys' in calls[1],false)
 const broken=new SupabaseRunRepository({rpc:async()=>({data:null,error:{message:'boom',code:'XX000'}})} as never)
 await assert.rejects(()=>broken.listDispatchable(1,new Date(T0),['local/fake']),(e:RepositoryError)=>e.code==='boom'||e.code==='rpc_failed')
})
