import { createHash, randomUUID } from 'crypto'
import type { Artifact } from './contract'
import { redact } from './redact'

// Every request payload is redacted HERE, at the persistence boundary, no matter what the caller did (defence in depth).
const safeRequest=(r:Record<string,unknown>)=>redact(r) as Record<string,unknown>

// Persistence port of the outbound executor. The real implementation (SupabaseRunRepository) maps 1:1 to the worker functions of
// 20260921_integration_run_state_machine_v1 (claim / complete / fail / cancel). InMemoryRunRepository mirrors the same semantics
// (unique identity, lease, fencing token, bounded attempts) so concurrency and recovery can be tested without a network.

export type ClaimOutcome='claimed'|'takeover'|'in_progress'|'replayed'|'cancelled'|'failed_terminal'|'retry_scheduled'
export type ClaimInput={
 organizationId:string;bindingId:string;adapterKey:string;capability:string;fingerprint:string
 actorUserId:string;maxAttempts:number;leaseSeconds:number;request:Record<string,unknown>;correlationId:string;now:Date
}
export type ClaimResult={
 runId:string;outcome:ClaimOutcome;claimToken:string|null;attemptCount:number;status:string
 nextAttemptAt:Date|null;externalRequestId:string|null;errorCode:string|null
}
export type CompleteInput={organizationId:string;runId:string;claimToken:string;externalRequestId:string|null;artifacts:Artifact[];now:Date}
export type CompleteOutcome='succeeded'|'duplicate_ignored'|'conflicting_duplicate'|'lease_lost'
export type FailInput={organizationId:string;runId:string;claimToken:string;code:string;message:string;retryable:boolean;backoffSeconds:number;now:Date}
export type FailOutcome='retry_scheduled'|'failed_terminal'|'lease_lost'

export type DispatchItem={
 runId:string;organizationId:string;bindingId:string;adapterKey:string;capability:string;fingerprint:string;correlationId:string
 status:string;attemptCount:number;maxAttempts:number;request:Record<string,unknown>;actorUserId:string
}
export type EnqueueInput={organizationId:string;bindingId:string;adapterKey:string;capability:string;fingerprint:string;actorUserId:string;maxAttempts:number;request:Record<string,unknown>;correlationId:string}
export type EnqueueResult={runId:string;status:string;created:boolean}
export type ReexecuteInput={organizationId:string;parentRunId:string;actorUserId:string;reason:string;correlationId:string}
export type ReexecuteResult={runId:string;fingerprint:string;created:boolean}

export interface RunRepository{
 // Governed request without execution. Idempotent per (tenant, binding, fingerprint).
 enqueue(input:EnqueueInput):Promise<EnqueueResult>
 // Work that may be eligible now: queued, retry due, expired lease. Advisory only: claim() stays the authority.
 // adapterKeys = only the adapters this worker can actually run (others must not occupy dispatch slots); undefined = no filter.
 listDispatchable(limit:number,now:Date,adapterKeys?:readonly string[]):Promise<DispatchItem[]>
 // NEW execution that points at a terminal parent (lineage). Not a retry: the parent is never touched.
 reexecute(input:ReexecuteInput):Promise<ReexecuteResult>
 claim(input:ClaimInput):Promise<ClaimResult>
 complete(input:CompleteInput):Promise<CompleteOutcome>
 fail(input:FailInput):Promise<FailOutcome>
 cancel(input:{organizationId:string;runId:string;actorUserId:string}):Promise<'cancelled'>
}

export class RepositoryError extends Error{constructor(readonly code:string,message?:string){super(message??code)}}

// ---------- Supabase (service role worker) ----------
type RpcClient={rpc(fn:string,args:Record<string,unknown>):PromiseLike<{data:unknown;error:{message:string;code?:string}|null}>}

const iso=(d:Date)=>d.toISOString()
const date=(v:unknown)=>typeof v==='string'?new Date(v):null

export class SupabaseRunRepository implements RunRepository{
 constructor(private readonly client:RpcClient){}
 private async call(fn:string,args:Record<string,unknown>):Promise<unknown>{
  const {data,error}=await this.client.rpc(fn,args)
  if(error){
   // PostgREST: the function (or that argument list) does not exist in this database yet (code deployed before its migration).
   if(error.code==='PGRST202')throw new RepositoryError('rpc_function_missing')
   // Surface only the stable error token raised by the database, never the raw statement or arguments.
   const token=/^[a-z_]+(?=[:\s]|$)/.exec(error.message)?.[0]??'rpc_failed'
   throw new RepositoryError(token,token)
  }
  return data
 }
 async enqueue(i:EnqueueInput):Promise<EnqueueResult>{
  const data=await this.call('enqueue_integration_run',{p_org:i.organizationId,p_binding:i.bindingId,p_capability:i.capability,p_fingerprint:i.fingerprint,p_actor:i.actorUserId,p_max_attempts:i.maxAttempts,p_request:safeRequest(i.request),p_correlation:i.correlationId,p_adapter_key:i.adapterKey})
  const row=(Array.isArray(data)?data[0]:data) as Record<string,unknown>|undefined
  if(!row||typeof row.run_id!=='string'||typeof row.status!=='string')throw new RepositoryError('enqueue_response_invalid')
  return {runId:row.run_id,status:row.status,created:row.created===true}
 }
 async listDispatchable(limit:number,now:Date,adapterKeys?:readonly string[]):Promise<DispatchItem[]>{
  const base={p_limit:Math.min(Math.max(1,limit),50),p_now:iso(now)}
  let data:unknown
  try{data=await this.call('list_dispatchable_integration_runs',{...base,p_adapter_keys:adapterKeys?[...adapterKeys]:null})}
  catch(e){
   // Compatibility while 20260923_worker_dispatch_hardening_v1 is not applied: the legacy 2-argument function, filtered here.
   // (Still correct; it only loses the SQL-side starvation protection until the migration is live.)
   if(!(e instanceof RepositoryError)||e.code!=='rpc_function_missing')throw e
   const legacy=await this.call('list_dispatchable_integration_runs',base)
   data=Array.isArray(legacy)&&adapterKeys?(legacy as Record<string,unknown>[]).filter(r=>adapterKeys.includes(String(r.adapter_key))):legacy
  }
  if(!Array.isArray(data))throw new RepositoryError('dispatch_response_invalid')
  return (data as Record<string,unknown>[]).map(r=>{
   if(typeof r.run_id!=='string'||typeof r.organization_id!=='string'||typeof r.binding_id!=='string'||typeof r.adapter_key!=='string'||typeof r.fingerprint!=='string'||typeof r.actor_user_id!=='string')throw new RepositoryError('dispatch_response_invalid')
   const req=r.request
   return {runId:r.run_id,organizationId:r.organization_id,bindingId:r.binding_id,adapterKey:r.adapter_key,capability:String(r.capability),fingerprint:r.fingerprint,correlationId:String(r.correlation_id??''),status:String(r.status),attemptCount:Number(r.attempt_count),maxAttempts:Number(r.max_attempts),request:req&&typeof req==='object'&&!Array.isArray(req)?req as Record<string,unknown>:{},actorUserId:r.actor_user_id}
  })
 }
 async reexecute(i:ReexecuteInput):Promise<ReexecuteResult>{
  const data=await this.call('create_integration_reexecution',{p_org:i.organizationId,p_parent:i.parentRunId,p_actor:i.actorUserId,p_reason:i.reason,p_correlation:i.correlationId})
  const row=(Array.isArray(data)?data[0]:data) as Record<string,unknown>|undefined
  if(!row||typeof row.run_id!=='string'||typeof row.fingerprint!=='string')throw new RepositoryError('reexecute_response_invalid')
  return {runId:row.run_id,fingerprint:row.fingerprint,created:row.created===true}
 }
 async claim(i:ClaimInput):Promise<ClaimResult>{
  const data=await this.call('claim_integration_run',{p_org:i.organizationId,p_binding:i.bindingId,p_capability:i.capability,p_fingerprint:i.fingerprint,p_actor:i.actorUserId,p_max_attempts:i.maxAttempts,p_lease_seconds:i.leaseSeconds,p_request:safeRequest(i.request),p_correlation:i.correlationId,p_now:iso(i.now),p_adapter_key:i.adapterKey})
  const row=(Array.isArray(data)?data[0]:data) as Record<string,unknown>|undefined
  if(!row||typeof row.run_id!=='string'||typeof row.outcome!=='string')throw new RepositoryError('claim_response_invalid')
  return {runId:row.run_id,outcome:row.outcome as ClaimOutcome,claimToken:(row.claim_token as string|null)??null,attemptCount:Number(row.attempt_count),status:String(row.status),nextAttemptAt:date(row.next_attempt_at),externalRequestId:(row.external_request_id as string|null)??null,errorCode:(row.error_code as string|null)??null}
 }
 async complete(i:CompleteInput):Promise<CompleteOutcome>{
  const data=await this.call('complete_integration_run',{p_org:i.organizationId,p_run:i.runId,p_token:i.claimToken,p_external_request_id:i.externalRequestId,p_artifacts:i.artifacts.map(a=>({kind:a.kind,payload:a.payload,sha256:a.sha256})),p_now:iso(i.now)})
  if(data!=='succeeded'&&data!=='duplicate_ignored'&&data!=='conflicting_duplicate'&&data!=='lease_lost')throw new RepositoryError('complete_response_invalid')
  return data
 }
 async fail(i:FailInput):Promise<FailOutcome>{
  const data=await this.call('fail_integration_run',{p_org:i.organizationId,p_run:i.runId,p_token:i.claimToken,p_code:i.code,p_message:i.message,p_retryable:i.retryable,p_backoff_seconds:i.backoffSeconds,p_now:iso(i.now)})
  if(data!=='retry_scheduled'&&data!=='failed_terminal'&&data!=='lease_lost')throw new RepositoryError('fail_response_invalid')
  return data
 }
 async cancel(i:{organizationId:string;runId:string;actorUserId:string}):Promise<'cancelled'>{
  const data=await this.call('cancel_integration_run',{p_org:i.organizationId,p_run:i.runId,p_actor:i.actorUserId})
  if(data!=='cancelled')throw new RepositoryError('cancel_response_invalid')
  return 'cancelled'
 }
}

// ---------- In-memory twin (tests / local development) ----------
type Mem={
 id:string;organizationId:string;bindingId:string;adapterKey:string;capability:string;fingerprint:string;status:'queued'|'running'|'succeeded'|'failed'|'cancelled'
 attemptCount:number;maxAttempts:number;claimToken:string|null;leaseExpiresAt:number|null;nextAttemptAt:number|null;terminal:boolean
 externalRequestId:string|null;errorCode:string|null;errorMessage:string|null;createdBy:string;correlationId:string;metadata:Record<string,unknown>
 artifacts:Artifact[];parentRunId:string|null;reexecutionReason:string|null
 history:{attempt:number;outcome:string;code?:string;message?:string}[]
}
export type MembershipCheck=(organizationId:string,userId:string,roles:readonly string[])=>boolean
export type BindingLookup=(organizationId:string,bindingId:string)=>{adapterKey:string;capabilities:readonly string[]}|null

export class InMemoryRunRepository implements RunRepository{
 readonly runs=new Map<string,Mem>()
 readonly artifacts:{runId:string;kind:string;sha256:string}[]=[]
 // A per-identity mutex stands in for SELECT ... FOR UPDATE: every operation is serialized on its run identity.
 private tails=new Map<string,Promise<unknown>>()
 constructor(private readonly opts:{isMember?:MembershipCheck;binding?:BindingLookup}={}){}
 private lock<T>(key:string,fn:()=>Promise<T>|T):Promise<T>{
  const prev=this.tails.get(key)??Promise.resolve()
  const next=prev.then(fn,fn)
  this.tails.set(key,next.catch(()=>undefined))
  return next as Promise<T>
 }
 private byIdentity(o:string,b:string,f:string){return [...this.runs.values()].find(r=>r.organizationId===o&&r.bindingId===b&&r.fingerprint===f)}
 async claim(i:ClaimInput):Promise<ClaimResult>{
  if(i.leaseSeconds<5||i.leaseSeconds>3600)throw new RepositoryError('invalid_lease')
  if(i.maxAttempts<1||i.maxAttempts>10)throw new RepositoryError('invalid_max_attempts')
  if(!/^[0-9a-f]{64}$/.test(i.fingerprint))throw new RepositoryError('invalid_fingerprint')
  if(this.opts.isMember&&!this.opts.isMember(i.organizationId,i.actorUserId,['admin','manager','supervisor']))throw new RepositoryError('actor_not_authorized')
  const b=this.opts.binding?.(i.organizationId,i.bindingId)
  if(this.opts.binding){
   if(!b)throw new RepositoryError('binding_not_found')
   if(b.adapterKey!==i.adapterKey)throw new RepositoryError('adapter_mismatch')
   if(!b.capabilities.includes(i.capability))throw new RepositoryError('adapter_capability_unavailable')
  }
  const key=`${i.organizationId}|${i.bindingId}|${i.fingerprint}`
  return this.lock(key,()=>{
   const now=i.now.getTime()
   let r=this.byIdentity(i.organizationId,i.bindingId,i.fingerprint)
   if(!r){
    r={id:randomUUID(),organizationId:i.organizationId,bindingId:i.bindingId,adapterKey:i.adapterKey,capability:i.capability,fingerprint:i.fingerprint,status:'queued',attemptCount:0,maxAttempts:i.maxAttempts,claimToken:null,leaseExpiresAt:null,nextAttemptAt:null,terminal:false,externalRequestId:null,errorCode:null,errorMessage:null,createdBy:i.actorUserId,correlationId:i.correlationId,metadata:{request:safeRequest(i.request)},artifacts:[],parentRunId:null,reexecutionReason:null,history:[]}
    this.runs.set(r.id,r)
   }
   const res=(outcome:ClaimOutcome,token:string|null=null):ClaimResult=>({runId:r!.id,outcome,claimToken:token,attemptCount:r!.attemptCount,status:r!.status,nextAttemptAt:r!.nextAttemptAt===null?null:new Date(r!.nextAttemptAt),externalRequestId:r!.externalRequestId,errorCode:r!.errorCode})
   if(r.status==='succeeded')return res('replayed')
   if(r.status==='cancelled')return res('cancelled')
   if(r.status==='failed'&&(r.terminal||r.attemptCount>=r.maxAttempts))return res('failed_terminal')
   if(r.status==='failed'&&r.nextAttemptAt!==null&&now<r.nextAttemptAt)return res('retry_scheduled')
   if(r.status==='running'&&r.leaseExpiresAt!==null&&r.leaseExpiresAt>now)return res('in_progress')
   if(r.status==='running')r.history.push({attempt:r.attemptCount,outcome:'lease_expired'})
   if(r.status==='running'&&r.attemptCount>=r.maxAttempts){
    r.status='failed';r.terminal=true;r.errorCode='terminal:lease_expired_attempts_exhausted';r.errorMessage='worker lease expired on the last attempt';r.nextAttemptAt=null;r.claimToken=null;r.leaseExpiresAt=null
    return res('failed_terminal')
   }
   const takeover=r.status==='running'
   r.status='running';r.attemptCount+=1;r.claimToken=randomUUID();r.leaseExpiresAt=now+i.leaseSeconds*1000;r.nextAttemptAt=null;r.errorCode=null;r.errorMessage=null;r.terminal=false
   return res(takeover?'takeover':'claimed',r.claimToken)
  })
 }
  history(runId:string){return this.runs.get(runId)?.history??[]}
 private checkActor(o:string,u:string,roles:readonly string[]){if(this.opts.isMember&&!this.opts.isMember(o,u,roles))throw new RepositoryError('actor_not_authorized')}
 async enqueue(i:EnqueueInput):Promise<EnqueueResult>{
  if(!/^[0-9a-f]{64}$/.test(i.fingerprint))throw new RepositoryError('invalid_fingerprint')
  this.checkActor(i.organizationId,i.actorUserId,['admin','manager','supervisor'])
  if(this.opts.binding){
   const b=this.opts.binding(i.organizationId,i.bindingId)
   if(!b)throw new RepositoryError('binding_not_found')
   if(b.adapterKey!==i.adapterKey)throw new RepositoryError('adapter_mismatch')
   if(!b.capabilities.includes(i.capability))throw new RepositoryError('adapter_capability_unavailable')
  }
  return this.lock(`${i.organizationId}|${i.bindingId}|${i.fingerprint}`,()=>{
   const ex=this.byIdentity(i.organizationId,i.bindingId,i.fingerprint)
   if(ex)return {runId:ex.id,status:ex.status,created:false}
   const r:Mem={id:randomUUID(),organizationId:i.organizationId,bindingId:i.bindingId,adapterKey:i.adapterKey,capability:i.capability,fingerprint:i.fingerprint,status:'queued',attemptCount:0,maxAttempts:i.maxAttempts,claimToken:null,leaseExpiresAt:null,nextAttemptAt:null,terminal:false,externalRequestId:null,errorCode:null,errorMessage:null,createdBy:i.actorUserId,correlationId:i.correlationId,metadata:{request:safeRequest(i.request)},artifacts:[],parentRunId:null,reexecutionReason:null,history:[]}
   this.runs.set(r.id,r)
   return {runId:r.id,status:'queued',created:true}
  })
 }
 // Same eligibility and ordering as the SQL function: by the moment the run became eligible, then creation.
 async listDispatchable(limit:number,now:Date,adapterKeys?:readonly string[]):Promise<DispatchItem[]>{
  const t=now.getTime()
  const since=(r:Mem)=>r.nextAttemptAt??r.leaseExpiresAt??0
  return [...this.runs.values()].filter(r=>(!adapterKeys||adapterKeys.includes(r.adapterKey))&&(r.status==='queued'||(r.status==='failed'&&!r.terminal&&r.attemptCount<r.maxAttempts&&r.nextAttemptAt!==null&&r.nextAttemptAt<=t)||(r.status==='running'&&r.leaseExpiresAt!==null&&r.leaseExpiresAt<=t)))
   .map((r,i)=>({r,i})).sort((a,b)=>since(a.r)-since(b.r)||a.i-b.i).map(x=>x.r)
   .slice(0,Math.min(Math.max(1,limit),50)).map(r=>({runId:r.id,organizationId:r.organizationId,bindingId:r.bindingId,adapterKey:r.adapterKey,capability:r.capability,fingerprint:r.fingerprint,correlationId:r.correlationId,status:r.status,attemptCount:r.attemptCount,maxAttempts:r.maxAttempts,request:(r.metadata.request as Record<string,unknown>)??{},actorUserId:r.createdBy}))
 }
 async reexecute(i:ReexecuteInput):Promise<ReexecuteResult>{
  this.checkActor(i.organizationId,i.actorUserId,['admin','manager'])
  if(i.reason.trim().length<10||i.reason.trim().length>500)throw new RepositoryError('reexecution_reason_length_invalid')
  return this.lock(i.parentRunId,()=>{
   const p=this.get(i.organizationId,i.parentRunId)
   const child=[...this.runs.values()].find(r=>r.parentRunId===p.id)
   if(child)return {runId:child.id,fingerprint:child.fingerprint,created:false}
   if(!((p.status==='failed'&&(p.terminal||p.attemptCount>=p.maxAttempts))||p.status==='cancelled'))throw new RepositoryError('parent_not_reexecutable')
   const fp=createHash('sha256').update(`${p.fingerprint}:reexec:${p.id}`).digest('hex')
   const r:Mem={...p,id:randomUUID(),fingerprint:fp,status:'queued',attemptCount:0,claimToken:null,leaseExpiresAt:null,nextAttemptAt:null,terminal:false,externalRequestId:null,errorCode:null,errorMessage:null,createdBy:i.actorUserId,correlationId:i.correlationId||p.correlationId,metadata:{request:p.metadata.request,reexecution_of:p.id},artifacts:[],parentRunId:p.id,reexecutionReason:i.reason.trim(),history:[]}
   this.runs.set(r.id,r)
   return {runId:r.id,fingerprint:fp,created:true}
  })
 }
 private get(o:string,id:string){const r=this.runs.get(id);if(!r||r.organizationId!==o)throw new RepositoryError('run_not_found');return r}
 async complete(i:CompleteInput):Promise<CompleteOutcome>{
  return this.lock(i.runId,()=>{
   const r=this.get(i.organizationId,i.runId)
   if(r.status==='succeeded')return r.externalRequestId===i.externalRequestId?'duplicate_ignored':'conflicting_duplicate'
   if(r.status!=='running'||r.claimToken!==i.claimToken)return 'lease_lost'
   if(!i.artifacts.some(a=>a.kind==='response_metadata'))throw new RepositoryError('success_requires_response_evidence')
   for(const a of i.artifacts){if(!this.artifacts.some(x=>x.runId===r.id&&x.kind===a.kind&&x.sha256===a.sha256)){this.artifacts.push({runId:r.id,kind:a.kind,sha256:a.sha256});r.artifacts.push(a)}}
   r.status='succeeded';r.externalRequestId=i.externalRequestId;r.errorCode=null;r.errorMessage=null;r.terminal=false;r.claimToken=null;r.leaseExpiresAt=null
   return 'succeeded'
  })
 }
 async fail(i:FailInput):Promise<FailOutcome>{
  return this.lock(i.runId,()=>{
   const r=this.get(i.organizationId,i.runId)
   if(r.status!=='running'||r.claimToken!==i.claimToken)return 'lease_lost'
   const terminal=!i.retryable||r.attemptCount>=r.maxAttempts
   r.history.push({attempt:r.attemptCount,outcome:terminal?'failed_terminal':'retry_scheduled',code:i.code.slice(0,80),message:i.message.slice(0,500)})
   r.status='failed';r.terminal=terminal;r.errorCode=i.retryable?i.code.slice(0,80):`terminal:${i.code.slice(0,80)}`;r.errorMessage=i.message.slice(0,500)
   r.nextAttemptAt=terminal?null:i.now.getTime()+Math.max(0,Math.min(i.backoffSeconds,3600))*1000;r.claimToken=null;r.leaseExpiresAt=null
   return terminal?'failed_terminal':'retry_scheduled'
  })
 }
 async cancel(i:{organizationId:string;runId:string;actorUserId:string}):Promise<'cancelled'>{
  if(this.opts.isMember&&!this.opts.isMember(i.organizationId,i.actorUserId,['admin','manager']))throw new RepositoryError('actor_not_authorized')
  return this.lock(i.runId,()=>{
   const r=this.get(i.organizationId,i.runId)
   if(r.status!=='queued'&&r.status!=='failed')throw new RepositoryError('illegal_integration_run_transition')
   r.status='cancelled';r.nextAttemptAt=null
   return 'cancelled' as const
  })
 }
}
