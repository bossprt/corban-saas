import { createHash } from 'crypto'

// Provider-agnostic outbound execution engine on top of the Integration Contract (integration_adapters /
// integration_source_bindings / integration_runs / integration_run_artifacts).
// Guarantees: idempotent by request fingerprint, no double submission while a run is in flight, bounded retries with backoff,
// crash recovery for stale RUNNING runs, terminal errors are never retried, secrets are never persisted, and nothing reaches
// an EXTERNAL provider unless the caller explicitly allows it (default: blocked). Bevicred is DEFERRED and always refused.
// It publishes no financial or operational truth: results are evidence handed back to the governed import/evidence paths.

export type RunStatus='queued'|'running'|'succeeded'|'failed'|'cancelled'

export type ExecutionRequest={
 organizationId:string
 bindingId:string
 adapterKey:string
 capability:string
 payload:Record<string,unknown>
}

export type ProviderResult=
 |{ok:true;externalRequestId?:string;artifacts?:{kind:'response_metadata'|'raw_payload'|'diagnostic';payload:Record<string,unknown>}[]}
 |{ok:false;retryable:boolean;code:string;message:string}

export interface ProviderAdapter{
 readonly key:string
 readonly contractVersion:string
 readonly capabilities:readonly string[]
 // true for adapters that talk to a real third party. They run only when the caller sets allowExternal.
 readonly external:boolean
 execute(request:ExecutionRequest,credentials:CredentialProvider):Promise<ProviderResult>
}

// Credentials are resolved at call time from a runtime secret store and never written to the ledger.
export interface CredentialProvider{get(name:string):Promise<string|undefined>}

export type RunRecord={
 id:string
 organizationId:string
 bindingId:string
 adapterKey:string
 capability:string
 fingerprint:string
 status:RunStatus
 attemptCount:number
 maxAttempts:number
 startedAtMs:number|null
 nextAttemptAtMs:number|null
 externalRequestId:string|null
 errorCode:string|null
 errorMessage:string|null
 metadata:Record<string,unknown>
}

export interface RunRepository{
 findByFingerprint(organizationId:string,bindingId:string,fingerprint:string):Promise<RunRecord|null>
 create(run:Omit<RunRecord,'id'>):Promise<RunRecord>
 update(id:string,patch:Partial<RunRecord>):Promise<RunRecord>
}

export type ExecuteOutcome=
 |{state:'succeeded';run:RunRecord;replayed:boolean}
 |{state:'failed';run:RunRecord}
 |{state:'retry_scheduled';run:RunRecord}
 |{state:'in_progress';run:RunRecord}
 |{state:'refused';reason:'provider_deferred'|'external_not_allowed'|'capability_unavailable'|'adapter_mismatch'}

export const DEFERRED_PROVIDERS=new Set(['bevi'])
const SECRET_KEY=/^(password|senha|secret|api_?key|token|access_token|refresh_token|client_secret|authorization)$/i
export const STALE_RUNNING_MS=10*60*1000

const stable=(v:unknown):string=>{
 if(v===null||typeof v!=='object')return JSON.stringify(v)
 if(Array.isArray(v))return `[${v.map(stable).join(',')}]`
 const o=v as Record<string,unknown>
 return `{${Object.keys(o).sort().map(k=>`${JSON.stringify(k)}:${stable(o[k])}`).join(',')}}`
}

export function redactSecrets(value:unknown):unknown{
 if(Array.isArray(value))return value.map(redactSecrets)
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value as Record<string,unknown>).map(([k,v])=>[k,SECRET_KEY.test(k)?'[redacted]':redactSecrets(v)]))
 return value
}

// Same request => same fingerprint (tenant, binding, capability and payload; secrets excluded so rotation does not fork identity).
export function requestFingerprint(r:ExecutionRequest){
 return createHash('sha256').update(stable({o:r.organizationId,b:r.bindingId,a:r.adapterKey,c:r.capability,p:redactSecrets(r.payload)})).digest('hex')
}

export const backoffMs=(attempt:number)=>Math.min(60*60*1000,30*1000*2**Math.max(0,attempt-1))

export async function executeRun(input:{
 repo:RunRepository
 adapter:ProviderAdapter
 request:ExecutionRequest
 credentials:CredentialProvider
 nowMs:number
 maxAttempts?:number
 allowExternal?:boolean
}):Promise<ExecuteOutcome>{
 const {repo,adapter,request,credentials,nowMs}=input
 const provider=request.adapterKey.split('/')[0]
 if(DEFERRED_PROVIDERS.has(provider)||DEFERRED_PROVIDERS.has(adapter.key.split('/')[0]))return {state:'refused',reason:'provider_deferred'}
 if(adapter.key!==request.adapterKey)return {state:'refused',reason:'adapter_mismatch'}
 if(!adapter.capabilities.includes(request.capability))return {state:'refused',reason:'capability_unavailable'}
 if(adapter.external&&!input.allowExternal)return {state:'refused',reason:'external_not_allowed'}

 const fingerprint=requestFingerprint(request)
 let run=await repo.findByFingerprint(request.organizationId,request.bindingId,fingerprint)
 if(run?.status==='succeeded')return {state:'succeeded',run,replayed:true}
 if(run?.status==='cancelled')return {state:'failed',run}
 if(run?.status==='running'&&run.startedAtMs!==null&&nowMs-run.startedAtMs<STALE_RUNNING_MS)return {state:'in_progress',run}
 if(run?.status==='failed'){
  if(run.attemptCount>=run.maxAttempts||run.errorCode?.startsWith('terminal:'))return {state:'failed',run}
  if(run.nextAttemptAtMs!==null&&nowMs<run.nextAttemptAtMs)return {state:'retry_scheduled',run}
 }
 if(!run){
  run=await repo.create({organizationId:request.organizationId,bindingId:request.bindingId,adapterKey:request.adapterKey,capability:request.capability,fingerprint,status:'queued',attemptCount:0,maxAttempts:input.maxAttempts??3,startedAtMs:null,nextAttemptAtMs:null,externalRequestId:null,errorCode:null,errorMessage:null,metadata:{request:redactSecrets(request.payload)}})
 }
 // A stale RUNNING run (crashed worker) is taken over: it counts as an attempt and is retried, never assumed successful.
 run=await repo.update(run.id,{status:'running',attemptCount:run.attemptCount+1,startedAtMs:nowMs,nextAttemptAtMs:null})
 let result:ProviderResult
 try{result=await adapter.execute(request,credentials)}
 catch(e){result={ok:false,retryable:true,code:'adapter_exception',message:e instanceof Error?e.message:'unknown'}}
 if(result.ok){
  run=await repo.update(run.id,{status:'succeeded',externalRequestId:result.externalRequestId??null,errorCode:null,errorMessage:null,metadata:{...run.metadata,artifacts:(result.artifacts??[]).map(a=>({kind:a.kind,payload:redactSecrets(a.payload)}))}})
  return {state:'succeeded',run,replayed:false}
 }
 const exhausted=run.attemptCount>=run.maxAttempts
 const terminal=!result.retryable||exhausted
 run=await repo.update(run.id,{status:'failed',errorCode:terminal&&!result.retryable?`terminal:${result.code}`:result.code,errorMessage:String(redactSecrets(result.message)).slice(0,500),nextAttemptAtMs:terminal?null:nowMs+backoffMs(run.attemptCount)})
 return terminal?{state:'failed',run}:{state:'retry_scheduled',run}
}

// In-memory repository and a deterministic local adapter: used by tests and local development. No network, no credentials.
export class InMemoryRunRepository implements RunRepository{
 readonly runs=new Map<string,RunRecord>()
 private seq=0
 async findByFingerprint(o:string,b:string,f:string){return [...this.runs.values()].find(r=>r.organizationId===o&&r.bindingId===b&&r.fingerprint===f)??null}
 async create(run:Omit<RunRecord,'id'>){
  if([...this.runs.values()].some(r=>r.organizationId===run.organizationId&&r.bindingId===run.bindingId&&r.fingerprint===run.fingerprint))throw new Error('unique_violation')
  const r={...run,id:`run-${++this.seq}`};this.runs.set(r.id,r);return r
 }
 async update(id:string,patch:Partial<RunRecord>){const cur=this.runs.get(id);if(!cur)throw new Error('run_not_found');const n={...cur,...patch};this.runs.set(id,n);return n}
}

export class LocalFakeAdapter implements ProviderAdapter{
 readonly key='local/fake';readonly contractVersion='1.0.0';readonly capabilities=['proposal_status','proposal_submit'] as const;readonly external=false
 calls=0
 constructor(private script:ProviderResult[]=[{ok:true,externalRequestId:'fake-1'}]){}
 async execute(_r:ExecutionRequest,credentials:CredentialProvider):Promise<ProviderResult>{
  void credentials
  const r=this.script[Math.min(this.calls,this.script.length-1)];this.calls++;return r
 }
}
