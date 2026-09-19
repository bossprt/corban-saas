import { randomUUID } from 'crypto'
import type { Artifact } from './contract'

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

export interface RunRepository{
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
   // Surface only the stable error token raised by the database, never the raw statement or arguments.
   const token=/^[a-z_]+(?=[:\s]|$)/.exec(error.message)?.[0]??'rpc_failed'
   throw new RepositoryError(token,token)
  }
  return data
 }
 async claim(i:ClaimInput):Promise<ClaimResult>{
  const data=await this.call('claim_integration_run',{p_org:i.organizationId,p_binding:i.bindingId,p_capability:i.capability,p_fingerprint:i.fingerprint,p_actor:i.actorUserId,p_max_attempts:i.maxAttempts,p_lease_seconds:i.leaseSeconds,p_request:i.request,p_correlation:i.correlationId,p_now:iso(i.now),p_adapter_key:i.adapterKey})
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
 artifacts:Artifact[]
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
    r={id:randomUUID(),organizationId:i.organizationId,bindingId:i.bindingId,adapterKey:i.adapterKey,capability:i.capability,fingerprint:i.fingerprint,status:'queued',attemptCount:0,maxAttempts:i.maxAttempts,claimToken:null,leaseExpiresAt:null,nextAttemptAt:null,terminal:false,externalRequestId:null,errorCode:null,errorMessage:null,createdBy:i.actorUserId,correlationId:i.correlationId,metadata:{request:i.request},artifacts:[]}
    this.runs.set(r.id,r)
   }
   const res=(outcome:ClaimOutcome,token:string|null=null):ClaimResult=>({runId:r!.id,outcome,claimToken:token,attemptCount:r!.attemptCount,status:r!.status,nextAttemptAt:r!.nextAttemptAt===null?null:new Date(r!.nextAttemptAt),externalRequestId:r!.externalRequestId,errorCode:r!.errorCode})
   if(r.status==='succeeded')return res('replayed')
   if(r.status==='cancelled')return res('cancelled')
   if(r.status==='failed'&&(r.terminal||r.attemptCount>=r.maxAttempts))return res('failed_terminal')
   if(r.status==='failed'&&r.nextAttemptAt!==null&&now<r.nextAttemptAt)return res('retry_scheduled')
   if(r.status==='running'&&r.leaseExpiresAt!==null&&r.leaseExpiresAt>now)return res('in_progress')
   if(r.status==='running'&&r.attemptCount>=r.maxAttempts){
    r.status='failed';r.terminal=true;r.errorCode='terminal:lease_expired_attempts_exhausted';r.errorMessage='worker lease expired on the last attempt';r.nextAttemptAt=null;r.claimToken=null;r.leaseExpiresAt=null
    return res('failed_terminal')
   }
   const takeover=r.status==='running'
   r.status='running';r.attemptCount+=1;r.claimToken=randomUUID();r.leaseExpiresAt=now+i.leaseSeconds*1000;r.nextAttemptAt=null;r.errorCode=null;r.errorMessage=null;r.terminal=false
   return res(takeover?'takeover':'claimed',r.claimToken)
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
