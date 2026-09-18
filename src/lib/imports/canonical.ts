import type { NormalizedImportRow } from './contract'

// Stable cross-provider canonical contract (v1).
// Provider-specific codes/names are ALIASES scoped by provider (and, when relevant, institution).
// They are never canonical enums: the canonical id always comes from a tenant-scoped record.

export const CANONICAL_CONTRACT_VERSION='1.0.0'

export type ExternalAliasKind=
 'institution'|'agreement'|'product'|'operation_form'|'contracting_channel'|'partner'|'producer'|
 'proposal'|'product_table'|'source_status'|'commission_component'

export type ExternalAlias={
 providerKey:string|null
 kind:ExternalAliasKind
 institutionKey:string|null
 code:string
}

export type CommissionComponentKind='upfront'|'deferred'|'anticipation'|'bonus'|'campaign'|'adjustment'|'reversal'
export type CommissionComponentObservation={
 kind:CommissionComponentKind
 // Decimal string, never a JS float. null = not reported (distinct from '0').
 value:string|null
 unit:'currency'|'percent'|'unknown'
}

export type SourceStatusObservation={
 dimension:'bank_client'|'company_vendor'|'proposal'|'other'
 rawValue:string
 // Canonical mapping requires an explicit policy/evidence; observations are never auto-promoted.
 canonicalStatus:null
}

export type CanonicalObservation={
 contractVersion:string
 providerKey:string|null
 institutionAlias:ExternalAlias|null
 proposalIdentity:ExternalAlias|null
 tableIdentity:ExternalAlias|null
 producerAlias:ExternalAlias|null
 operationFormAlias:ExternalAlias|null
 termMonths:number|null
 rate:string|null
 commissionComponents:CommissionComponentObservation[]
 sourceStatuses:SourceStatusObservation[]
}

export const normalizeAliasCode=(value:string|null|undefined)=>{
 if(value==null)return null
 const v=String(value).normalize('NFC').trim().replace(/\s+/g,' ')
 return v||null
}

const alias=(providerKey:string|null,kind:ExternalAliasKind,code:string|null,institutionKey:string|null):ExternalAlias|null=>{
 const c=normalizeAliasCode(code)
 return c?{providerKey,kind,institutionKey:normalizeAliasCode(institutionKey)?.toLowerCase()??null,code:c}:null
}

const STATUS_DIMENSIONS:Record<string,SourceStatusObservation['dimension']>={bank_client:'bank_client',company_vendor:'company_vendor',proposal:'proposal'}

export function toCanonicalObservation(row:NormalizedImportRow,providerKey:string|null):CanonicalObservation{
 const payload=row.normalizedPayload as {source_status?:Record<string,unknown>}
 const institution=normalizeAliasCode(row.bankKey)?.toLowerCase()??null
 const sourceStatuses:SourceStatusObservation[]=[]
 for(const [dim,v] of Object.entries(payload.source_status??{})){
  const raw=normalizeAliasCode(v==null?null:String(v))
  if(raw)sourceStatuses.push({dimension:STATUS_DIMENSIONS[dim]??'other',rawValue:raw,canonicalStatus:null})
 }
 const components:CommissionComponentObservation[]=[]
 if(row.commissionUpfront!==null)components.push({kind:'upfront',value:row.commissionUpfront,unit:'unknown'})
 if(row.commissionDeferred!==null)components.push({kind:'deferred',value:row.commissionDeferred,unit:'unknown'})
 return {
  contractVersion:CANONICAL_CONTRACT_VERSION,
  providerKey,
  institutionAlias:alias(providerKey,'institution',row.bankKey,null),
  proposalIdentity:alias(providerKey,'proposal',row.externalProposalNumber,institution),
  tableIdentity:alias(providerKey,'product_table',row.externalTableCode,institution),
  producerAlias:alias(providerKey,'producer',row.producerTaxId,null),
  operationFormAlias:alias(providerKey,'operation_form',row.operationType,institution),
  termMonths:row.term,
  rate:row.rate,
  commissionComponents:components,
  sourceStatuses
 }
}

// Canonical identity of an external proposal: institution + number. The provider is deliberately NOT part
// of the key so the same proposal seen via 2Tech, a bank portal or an API resolves to one identity.
export function proposalIdentityKey(a:ExternalAlias|null):string|null{
 if(!a)return null
 return `${a.institutionKey??'unknown'}::${a.code}`
}
