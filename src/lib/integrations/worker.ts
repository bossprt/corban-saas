import { timingSafeEqual } from 'crypto'
import type { CredentialProvider, ProviderAdapter } from './contract'
import { executeRun, type ExecuteOutcome } from './executor'
import { nullLogger, type RunLogger } from './observability'
import { RepositoryError, type DispatchItem, type RunRepository } from './repository'
import { findProvider, usability } from './registry'
import { redactMessage } from './redact'

// Worker core. Pure (no Next.js, no Supabase import) so it is unit-testable; worker.server.ts wires it to the service role.
// One cycle = one bounded pass over currently eligible work. There is no loop, no timer and no cron here: something external
// (a route, a CLI, a queue) calls runDispatchCycle. Eligibility from listDispatchable is ADVISORY; claim() in the database decides.

export const MAX_CYCLE_ITEMS=25

export type LocalProviderEnv={NODE_ENV?:string;CORBAN_ALLOW_LOCAL_PROVIDERS?:string}
// Local/fake providers can never be selected in production, and elsewhere only with an explicit flag.
// Explicit allow-list: an unset / unknown / misspelled NODE_ENV is NOT enough, and neither is the flag alone.
export const localProvidersAllowed=(env:LocalProviderEnv)=>(env.NODE_ENV==='development'||env.NODE_ENV==='test')&&env.CORBAN_ALLOW_LOCAL_PROVIDERS==='1'

export type ProviderFactories=Readonly<Record<string,()=>ProviderAdapter>>

export function resolveProvider(adapterKey:string,factories:ProviderFactories,env:LocalProviderEnv):ProviderAdapter|null{
 const entry=findProvider(adapterKey)
 if(!entry)return null
 const factory=Object.prototype.hasOwnProperty.call(factories,adapterKey)?factories[adapterKey]:undefined
 if(!factory)return null
 if(entry.homologation==='local_only'&&!localProvidersAllowed(env))return null
 if(!usability(adapterKey).usable)return null
 const adapter=factory()
 // The adapter must be exactly what the registry describes: no swapping a manifest behind the registry's back.
 if(adapter.manifest.adapterKey!==adapterKey||adapter.manifest.external!==entry.manifest.external)return null
 return adapter
}

export type CycleSummary={
 examined:number;succeeded:number;replayed:number;retryScheduled:number;failed:number;inProgress:number;leaseLost:number;refused:number;errors:number
 runs:{runId:string;state:string}[]
}

export type WorkerDeps={
 repo:RunRepository
 factories:ProviderFactories
 env:LocalProviderEnv
 credentials:CredentialProvider
 now?:()=>Date
 logger?:RunLogger
 limit?:number
 leaseSeconds?:number
 timeoutMs?:number
 // restrict the pass to a single run (used by the governed "Nova tentativa" action)
 onlyRunId?:string
}

const empty=():CycleSummary=>({examined:0,succeeded:0,replayed:0,retryScheduled:0,failed:0,inProgress:0,leaseLost:0,refused:0,errors:0,runs:[]})

export async function runDispatchCycle(deps:WorkerDeps):Promise<CycleSummary>{
 const now=deps.now??(()=>new Date())
 const logger=deps.logger??nullLogger
 const limit=Math.min(Math.max(1,deps.limit??10),MAX_CYCLE_ITEMS)
 const sum=empty()
 // The repository already caps its own list; over-fetch a little when filtering to one run so it is not crowded out.
 // Only ask for runs whose adapter this worker can really run: unrunnable adapters (2Tech without a file, Bevicred, local in
 // production) must never occupy dispatch slots and starve runnable work.
 const runnable=Object.keys(deps.factories).filter(k=>resolveProvider(k,deps.factories,deps.env)!==null)
 if(!runnable.length)return sum
 let items:DispatchItem[]=await deps.repo.listDispatchable(deps.onlyRunId?50:limit,now(),runnable)
 if(deps.onlyRunId)items=items.filter(i=>i.runId===deps.onlyRunId)
 items=items.slice(0,limit)
 for(const item of items){
  sum.examined++
  const adapter=resolveProvider(item.adapterKey,deps.factories,deps.env)
  if(!adapter){sum.refused++;sum.runs.push({runId:item.runId,state:'refused'});continue}
  let out:ExecuteOutcome
  try{
   out=await executeRun({repo:deps.repo,adapter,fingerprint:item.fingerprint,maxAttempts:item.maxAttempts,leaseSeconds:deps.leaseSeconds,timeoutMs:deps.timeoutMs,now,logger,credentials:deps.credentials,
    request:{organizationId:item.organizationId,bindingId:item.bindingId,actorUserId:item.actorUserId,capability:item.capability,payload:item.request,correlationId:item.correlationId||undefined}})
  }catch(e){
   // e.g. actor_not_authorized (membership revoked): the run stays as the database left it; the cycle continues.
   sum.errors++;sum.runs.push({runId:item.runId,state:`error:${e instanceof RepositoryError?e.code:'unexpected'}`})
   logger.log({event:'repository_error',level:'error',correlationId:item.correlationId||'n/a',runId:item.runId,provider:adapter.manifest.provider,adapter:adapter.manifest.adapterKey,capability:item.capability,errorCode:e instanceof RepositoryError?e.code:'unexpected',errorMessage:redactMessage(e)})
   continue
  }
  sum.runs.push({runId:item.runId,state:out.state})
  switch(out.state){
   case'succeeded':if(out.replayed)sum.replayed++;else sum.succeeded++;break
   case'retry_scheduled':sum.retryScheduled++;break
   case'failed':sum.failed++;break
   case'in_progress':sum.inProgress++;break
   case'lease_lost':sum.leaseLost++;break
   case'refused':sum.refused++;break
  }
 }
 return sum
}

// Authorization of the dispatch trigger (route / CLI): shared secret compared in constant time. Unset/weak secret = trigger disabled.
// Scheme is case-insensitive (RFC 9110); the credential is exactly one token: no surrounding or embedded whitespace, no list of values.
export function authorizeWorkerRequest(authorizationHeader:string|null|undefined,secret:string|undefined):'ok'|'disabled'|'forbidden'{
 if(!secret||secret.length<24)return 'disabled'
 const m=/^bearer +(\S+)$/i.exec(authorizationHeader??'')
 if(!m)return 'forbidden'
 const a=Buffer.from(m[1]);const b=Buffer.from(secret)
 return a.length===b.length&&timingSafeEqual(a,b)?'ok':'forbidden'
}

// The whole dispatch endpoint as a pure function (the route only adapts Request/Response). Bodies carry counts and stable codes only:
// never the secret, never the presented credential, never an exception message, never a run payload.
export type DispatchHttp={status:200|403|500|503;body:Record<string,unknown>}
export async function handleDispatchRequest(input:{authorization:string|null|undefined;secret:string|undefined;run:()=>Promise<CycleSummary>}):Promise<DispatchHttp>{
 const auth=authorizeWorkerRequest(input.authorization,input.secret)
 if(auth==='disabled')return {status:503,body:{error:'dispatch_disabled'}}
 if(auth==='forbidden')return {status:403,body:{error:'forbidden'}}
 try{
  const {runs,...counts}=await input.run()
  return {status:200,body:{ok:true,...counts,runs:runs.length}}
 }catch{return {status:500,body:{error:'dispatch_failed'}}}
}
