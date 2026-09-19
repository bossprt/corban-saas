import type { CapabilityManifest } from './contract'
import { TWOTECH_ADAPTER_KEY, TWOTECH_CONTRACT_VERSION, KNOWN_TWOTECH_SCHEMA_FINGERPRINTS } from '../imports/twotech'
import { FAKE_FILE_MANIFEST, FAKE_MANIFEST } from './fake-provider'

// Provider registry: what exists, what it can do, and whether it may run at all. Homologation state is DATA, so "first real provider"
// is a registry decision plus evidence, never a code path hidden behind an `if (provider === ...)`.
export type HomologationState=
 |'local_only'            // deterministic local providers (fake)
 |'awaiting_real_file'    // boundary ready, blocked until a real export exists and its schema fingerprint is registered
 |'deferred'              // explicitly out of scope
 |'homologated'

export type RegistryEntry={manifest:CapabilityManifest;homologation:HomologationState;blockedReason:string|null}

// Mirrors the live integration_adapters catalog row for 2tech/busca_contrato_file (capabilities are evidence semantics, not API verbs).
export const TWOTECH_MANIFEST:CapabilityManifest={
 provider:'2tech',adapterKey:TWOTECH_ADAPTER_KEY,contractVersion:TWOTECH_CONTRACT_VERSION,transport:'file',external:false,
 capabilities:{
  proposal:{idempotent:true,mode:'async',mutating:false},
  status:{idempotent:true,mode:'async',mutating:false},
  production:{idempotent:true,mode:'async',mutating:false},
  commission:{idempotent:true,mode:'async',mutating:false},
  commercial_lineage:{idempotent:true,mode:'async',mutating:false}
 }
}

// Bevicred stays DEFERRED: the manifest only documents the catalog row; the executor refuses it unconditionally.
export const BEVI_MANIFEST:CapabilityManifest={
 provider:'bevi',adapterKey:'bevi/webservice_agente',contractVersion:'1.0.0',transport:'api',external:true,
 capabilities:{contract_pending_physical:{idempotent:true,mode:'sync',mutating:false},contract_pending_issue:{idempotent:true,mode:'sync',mutating:false},paid_incentives:{idempotent:true,mode:'sync',mutating:false},bank_production:{idempotent:true,mode:'sync',mutating:false},workbank:{idempotent:true,mode:'sync',mutating:false},synthetic_production:{idempotent:true,mode:'sync',mutating:false},adhesion_lookup:{idempotent:true,mode:'sync',mutating:false}}
}

export const PROVIDER_REGISTRY:readonly RegistryEntry[]=[
 {manifest:FAKE_MANIFEST,homologation:'local_only',blockedReason:null},
 {manifest:FAKE_FILE_MANIFEST,homologation:'local_only',blockedReason:null},
 {manifest:TWOTECH_MANIFEST,homologation:'awaiting_real_file',blockedReason:'No real BuscaContrato export has been registered; header aliases are provisional and the schema fingerprint list is empty.'},
 {manifest:BEVI_MANIFEST,homologation:'deferred',blockedReason:'Bevicred integration is deferred by decision.'}
]

export const findProvider=(adapterKey:string)=>PROVIDER_REGISTRY.find(e=>e.manifest.adapterKey===adapterKey)??null

// A provider may be used for real work only when homologated (or local). Anything else is a hard stop with a reason.
export function usability(adapterKey:string):{usable:true}|{usable:false;reason:string}{
 const e=findProvider(adapterKey)
 if(!e)return {usable:false,reason:'unknown_provider'}
 if(e.homologation==='local_only')return {usable:true}
 if(e.homologation==='homologated'){
  if(e.manifest.adapterKey===TWOTECH_ADAPTER_KEY&&KNOWN_TWOTECH_SCHEMA_FINGERPRINTS.length===0)return {usable:false,reason:'no_registered_schema_fingerprint'}
  return {usable:true}
 }
 return {usable:false,reason:e.blockedReason??e.homologation}
}
