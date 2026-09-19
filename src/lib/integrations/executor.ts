import { createHash } from 'crypto'
import { declares, parseProviderResult, stableStringify, type CredentialProvider, type ProviderAdapter } from './contract'
import { redact, redactMessage } from './redact'
import { nullLogger, type ExecEvent, type RunLogger } from './observability'
import { RepositoryError, type RunRepository } from './repository'

// Provider-agnostic outbound execution engine on top of the Integration Contract (integration_adapters /
// integration_source_bindings / integration_runs / integration_run_artifacts).
// Guarantees: idempotent by request fingerprint; ownership by lease + fencing token held in the DATABASE (not in memory), so two
// workers can never both run the same operation and a late worker cannot overwrite a newer one; bounded retries with backoff;
// crash recovery by lease takeover; terminal errors are never retried; success requires deterministic evidence; secrets are
// redacted before anything is persisted or logged; nothing reaches an EXTERNAL provider unless the caller explicitly allows it.
// Bevicred is DEFERRED and always refused. The executor publishes no financial or operational truth: results are evidence.

export type ExecutionRequest={
 organizationId:string
 bindingId:string
 actorUserId:string
 capability:string
 payload:Record<string,unknown>
 correlationId?:string
}

export type ExecuteOutcome=
 |{state:'succeeded';runId:string;replayed:boolean;externalRequestId:string|null;duplicate?:'ignored'|'conflicting'}
 |{state:'failed';runId:string;errorCode:string|null}
 |{state:'retry_scheduled';runId:string;nextAttemptAt:Date|null}
 |{state:'in_progress';runId:string}
 |{state:'lease_lost';runId:string}
 |{state:'refused';reason:'provider_deferred'|'external_not_allowed'|'capability_unavailable'|'adapter_mismatch'|'invalid_request'}

export const DEFERRED_PROVIDERS=new Set(['bevi'])
export const DEFAULT_LEASE_SECONDS=300
export const DEFAULT_TIMEOUT_MS=30_000
export const backoffSeconds=(attempt:number)=>Math.min(3600,30*2**Math.max(0,attempt-1))

// Same request => same fingerprint (tenant, binding, adapter, capability and redacted payload; secrets excluded so rotation does not fork identity).
export function requestFingerprint(r:Pick<ExecutionRequest,'organizationId'|'bindingId'|'capability'|'payload'>,adapterKey:string){
 return createHash('sha256').update(stableStringify({o:r.organizationId,b:r.bindingId,a:adapterKey,c:r.capability,p:redact(r.payload)})).digest('hex')
}

class TimeoutError extends Error{constructor(){super('provider_timeout');this.name='TimeoutError'}}

async function withTimeout<T>(run:(signal:AbortSignal)=>Promise<T>,ms:number):Promise<T>{
 const ac=new AbortController()
 let timer:ReturnType<typeof setTimeout>|undefined
 const timeout=new Promise<never>((_,rej)=>{timer=setTimeout(()=>{ac.abort();rej(new TimeoutError())},ms)})
 try{return await Promise.race([run(ac.signal),timeout])}finally{if(timer)clearTimeout(timer)}
}

export async function executeRun(input:{
 repo:RunRepository
 adapter:ProviderAdapter
 request:ExecutionRequest
 credentials:CredentialProvider
 now?:()=>Date
 maxAttempts?:number
 leaseSeconds?:number
 timeoutMs?:number
 allowExternal?:boolean
 logger?:RunLogger
 // Stored identity of an already-enqueued run (dispatch / re-execution). Otherwise derived from the request.
 fingerprint?:string
}):Promise<ExecuteOutcome>{
 const {repo,adapter,request,credentials}=input
 const now=input.now??(()=>new Date())
 const logger=input.logger??nullLogger
 const m=adapter.manifest
 const correlationId=request.correlationId??createHash('sha256').update(`${request.organizationId}|${request.bindingId}|${request.capability}|${now().getTime()}`).digest('hex').slice(0,16)
 const base={correlationId,provider:m.provider,adapter:m.adapterKey,capability:request.capability}
 const emit=(e:Omit<ExecEvent,'correlationId'|'provider'|'adapter'|'capability'>)=>logger.log({...base,...e})
 const refuse=(reason:Extract<ExecuteOutcome,{state:'refused'}>['reason']):ExecuteOutcome=>{emit({event:'run_refused',level:'warn',outcome:reason});return {state:'refused',reason}}

 if(!request.organizationId||!request.bindingId||!request.actorUserId)return refuse('invalid_request')
 if(DEFERRED_PROVIDERS.has(m.provider)||DEFERRED_PROVIDERS.has(m.adapterKey.split('/')[0]))return refuse('provider_deferred')
 if(!declares(m,request.capability))return refuse('capability_unavailable')
 if(m.external&&!input.allowExternal)return refuse('external_not_allowed')

 const leaseSeconds=input.leaseSeconds??DEFAULT_LEASE_SECONDS
 const timeoutMs=Math.min(input.timeoutMs??DEFAULT_TIMEOUT_MS,(leaseSeconds-1)*1000)
 const fingerprint=input.fingerprint??requestFingerprint(request,m.adapterKey)
 let claim
 try{
  claim=await repo.claim({organizationId:request.organizationId,bindingId:request.bindingId,adapterKey:m.adapterKey,capability:request.capability,fingerprint,actorUserId:request.actorUserId,maxAttempts:input.maxAttempts??3,leaseSeconds,request:redact(request.payload) as Record<string,unknown>,correlationId,now:now()})
 }catch(e){
  if(e instanceof RepositoryError&&e.code==='adapter_mismatch')return refuse('adapter_mismatch')
  emit({event:'repository_error',level:'error',errorCode:e instanceof RepositoryError?e.code:'repository_failure',errorMessage:redactMessage(e)})
  throw e
 }
 const runId=claim.runId
 switch(claim.outcome){
  case'replayed':emit({event:'run_replayed',level:'info',runId,attempt:claim.attemptCount,outcome:'succeeded'});return {state:'succeeded',runId,replayed:true,externalRequestId:claim.externalRequestId}
  case'in_progress':emit({event:'run_in_progress',level:'info',runId,attempt:claim.attemptCount});return {state:'in_progress',runId}
  case'retry_scheduled':return {state:'retry_scheduled',runId,nextAttemptAt:claim.nextAttemptAt}
  case'cancelled':return {state:'failed',runId,errorCode:'cancelled'}
  case'failed_terminal':return {state:'failed',runId,errorCode:claim.errorCode}
 }
 const token=claim.claimToken
 if(!token)throw new RepositoryError('claim_token_missing')
 const attempt=claim.attemptCount
 emit({event:'run_claimed',level:'info',runId,attempt,outcome:claim.outcome})

 const started=Date.now()
 let raw:unknown
 let thrown:{code:string;message:string;retryable:boolean}|null=null
 try{
  raw=await withTimeout(signal=>adapter.execute({capability:request.capability,payload:request.payload,idempotencyKey:fingerprint},{credentials,signal,correlationId,attempt}),timeoutMs)
 }catch(e){
  thrown=e instanceof TimeoutError?{code:'timeout',message:'provider did not answer in time',retryable:true}:{code:'adapter_exception',message:redactMessage(e),retryable:true}
 }
 const durationMs=Date.now()-started
 emit({event:'provider_called',level:'info',runId,attempt,durationMs,outcome:thrown?thrown.code:'returned'})

 type Failure={code:string;message:string;retryable:boolean}
 let failure:Failure|null=thrown
 let success:Extract<ReturnType<typeof parseProviderResult>,{ok:true}>['result']|null=null
 if(!failure){
  const parsed=parseProviderResult(raw)
  if(!parsed.ok)failure={code:'malformed_response',message:`provider response rejected: ${parsed.reason}`,retryable:false}
  else if(parsed.result.ok)success=parsed.result
  else failure={code:parsed.result.code,message:redactMessage(parsed.result.message),retryable:parsed.result.retryable}
 }

 if(success&&success.ok){
  const out=await repo.complete({organizationId:request.organizationId,runId,claimToken:token,externalRequestId:success.externalRequestId,artifacts:success.artifacts,now:now()})
  if(out==='lease_lost'){emit({event:'run_lease_lost',level:'warn',runId,attempt});return {state:'lease_lost',runId}}
  if(out!=='succeeded')emit({event:'run_duplicate_result',level:out==='conflicting_duplicate'?'error':'warn',runId,attempt,outcome:out})
  emit({event:'run_succeeded',level:'info',runId,attempt,durationMs,outcome:out})
  return {state:'succeeded',runId,replayed:false,externalRequestId:success.externalRequestId,...(out==='duplicate_ignored'?{duplicate:'ignored' as const}:out==='conflicting_duplicate'?{duplicate:'conflicting' as const}:{})}
 }
 const f=failure as Failure
 const out=await repo.fail({organizationId:request.organizationId,runId,claimToken:token,code:f.code,message:f.message,retryable:f.retryable,backoffSeconds:backoffSeconds(attempt),now:now()})
 if(out==='lease_lost'){emit({event:'run_lease_lost',level:'warn',runId,attempt});return {state:'lease_lost',runId}}
 if(out==='failed_terminal'){emit({event:'run_failed',level:'error',runId,attempt,durationMs,errorCode:f.code,errorMessage:f.message,outcome:'terminal'});return {state:'failed',runId,errorCode:f.retryable?f.code:`terminal:${f.code}`}}
 emit({event:'run_retry_scheduled',level:'warn',runId,attempt,durationMs,errorCode:f.code,errorMessage:f.message})
 return {state:'retry_scheduled',runId,nextAttemptAt:new Date(now().getTime()+backoffSeconds(attempt)*1000)}
}
