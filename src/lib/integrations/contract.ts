import { createHash } from 'crypto'
import { redact } from './redact'

// Provider-agnostic outbound contract. A provider declares WHAT IT CAN DO in a manifest; the executor and the UI consult the
// manifest, so there is no `if (provider === ...)` anywhere. Providers may be APIs or file based and do not all support the
// same operations.

export const KNOWN_CAPABILITIES=['submit','status','proposal_lookup','contract_lookup','simulation','cancel'] as const
export type KnownCapability=typeof KNOWN_CAPABILITIES[number]

export type CapabilitySpec={
 // true when repeating the call with the same idempotency key is safe for the provider
 idempotent:boolean
 mode:'sync'|'async'
 // an operation that changes state at the provider (submit, cancel) vs a read
 mutating:boolean
}

export type CapabilityManifest={
 provider:string
 adapterKey:string
 contractVersion:string
 transport:'api'|'file'
 // true for adapters that talk to a real third party; blocked unless the caller explicitly allows it
 external:boolean
 capabilities:Readonly<Record<string,CapabilitySpec>>
}

export const declares=(m:CapabilityManifest,capability:string)=>Object.prototype.hasOwnProperty.call(m.capabilities,capability)
export const capabilityNames=(m:CapabilityManifest)=>Object.keys(m.capabilities).sort()

export type ProviderCall={capability:string;payload:Record<string,unknown>;idempotencyKey:string}
export type CredentialProvider={get(name:string):Promise<string|undefined>}
export type ProviderContext={credentials:CredentialProvider;signal:AbortSignal;correlationId:string;attempt:number}

export interface ProviderAdapter{
 readonly manifest:CapabilityManifest
 // Raw result is validated by the executor; a provider cannot "declare" success by returning a truthy value.
 execute(call:ProviderCall,ctx:ProviderContext):Promise<unknown>
}

export type ArtifactKind='response_metadata'|'raw_payload'|'diagnostic'
export type Artifact={kind:ArtifactKind;payload:Record<string,unknown>;sha256:string}

export type ProviderResult=
 |{ok:true;externalRequestId:string|null;artifacts:Artifact[]}
 |{ok:false;retryable:boolean;code:string;message:string}

const KINDS:ArtifactKind[]=['response_metadata','raw_payload','diagnostic']
const stable=(v:unknown):string=>{
 if(v===null||typeof v!=='object')return JSON.stringify(v)
 if(Array.isArray(v))return `[${v.map(stable).join(',')}]`
 const o=v as Record<string,unknown>
 return `{${Object.keys(o).sort().map(k=>`${JSON.stringify(k)}:${stable(o[k])}`).join(',')}}`
}
export const stableStringify=stable
export const sha256Of=(v:unknown)=>createHash('sha256').update(stable(v)).digest('hex')

// Deterministic evidence gate: a success is only accepted when the provider returned a response_metadata artifact.
// Everything is redacted and hashed here (dedupe key for duplicate provider responses).
export function parseProviderResult(raw:unknown):{ok:true;result:ProviderResult}|{ok:false;reason:string}{
 if(raw===null||typeof raw!=='object'||Array.isArray(raw))return {ok:false,reason:'result_not_an_object'}
 const r=raw as Record<string,unknown>
 if(r.ok===false){
  if(typeof r.code!=='string'||!r.code||typeof r.retryable!=='boolean')return {ok:false,reason:'failure_shape_invalid'}
  return {ok:true,result:{ok:false,retryable:r.retryable,code:r.code.slice(0,80),message:typeof r.message==='string'?r.message:''}}
 }
 if(r.ok!==true)return {ok:false,reason:'ok_flag_missing'}
 if(r.externalRequestId!==undefined&&r.externalRequestId!==null&&(typeof r.externalRequestId!=='string'||!r.externalRequestId||r.externalRequestId.length>200))return {ok:false,reason:'external_request_id_invalid'}
 if(!Array.isArray(r.artifacts)||r.artifacts.length===0||r.artifacts.length>20)return {ok:false,reason:'artifacts_missing_or_too_many'}
 const artifacts:Artifact[]=[]
 for(const a of r.artifacts){
  if(a===null||typeof a!=='object')return {ok:false,reason:'artifact_invalid'}
  const x=a as Record<string,unknown>
  if(!KINDS.includes(x.kind as ArtifactKind))return {ok:false,reason:'artifact_kind_invalid'}
  if(x.payload===null||typeof x.payload!=='object'||Array.isArray(x.payload))return {ok:false,reason:'artifact_payload_invalid'}
  const payload=redact(x.payload) as Record<string,unknown>
  artifacts.push({kind:x.kind as ArtifactKind,payload,sha256:sha256Of({k:x.kind,p:payload})})
 }
 if(!artifacts.some(a=>a.kind==='response_metadata'))return {ok:false,reason:'response_evidence_missing'}
 return {ok:true,result:{ok:true,externalRequestId:(r.externalRequestId as string|null|undefined)??null,artifacts}}
}
