import { createHash } from 'crypto'
import type { NormalizedImportRow } from './contract'
import { proposalIdentityKey,toCanonicalObservation } from './canonical'

// Deterministic conflict detection over normalized rows of ONE tenant. The caller must load rows through
// tenant-scoped (RLS) queries; this module never merges data across organizations.
// Findings are advisory: they route rows to human review and never publish or mutate financial truth.

export type ConflictRow={
 ref:string
 organizationId:string
 sourceId:string
 providerKey:string|null
 batchId:string
 occurredAt:string|null
 normalized:NormalizedImportRow
}

export type ConflictKind=
 'replay'|'duplicate_in_batch'|'multi_source_same_proposal'|'contradictory_status'|
 'later_correction'|'ambiguous_identity'|'cross_tenant_rows'|'missing_identity'

export type ConflictFinding={
 kind:ConflictKind
 severity:'info'|'review'|'block'
 identityKey:string|null
 rowRefs:string[]
 detail:Record<string,unknown>
 // Always false: a finding can never authorize automatic financial publication.
 autoPublishAllowed:false
}

const stable=(v:unknown):string=>{
 if(v===null||typeof v!=='object')return JSON.stringify(v)
 if(Array.isArray(v))return `[${v.map(stable).join(',')}]`
 const o=v as Record<string,unknown>
 return `{${Object.keys(o).sort().map(k=>`${JSON.stringify(k)}:${stable(o[k])}`).join(',')}}`
}
export const rowContentHash=(row:ConflictRow)=>createHash('sha256').update(stable(row.normalized)).digest('hex')

const finding=(kind:ConflictKind,severity:ConflictFinding['severity'],identityKey:string|null,rowRefs:string[],detail:Record<string,unknown>={}):ConflictFinding=>
 ({kind,severity,identityKey,rowRefs,detail,autoPublishAllowed:false})

function statusMap(row:ConflictRow){
 const obs=toCanonicalObservation(row.normalized,row.providerKey)
 return Object.fromEntries(obs.sourceStatuses.map(s=>[s.dimension,s.rawValue]))
}

export function detectConflicts(rows:ConflictRow[]):ConflictFinding[]{
 const out:ConflictFinding[]=[]
 const orgs=new Set(rows.map(r=>r.organizationId))
 if(orgs.size>1){
  // Fail closed: mixed tenants must never be compared or merged.
  return [finding('cross_tenant_rows','block',null,rows.map(r=>r.ref),{organizations:orgs.size})]
 }
 const groups=new Map<string,ConflictRow[]>()
 for(const r of rows){
  const obs=toCanonicalObservation(r.normalized,r.providerKey)
  const key=proposalIdentityKey(obs.proposalIdentity)
  if(!key){
   if(['proposal','commission','payment','status'].includes(r.normalized.recordKind))out.push(finding('missing_identity','review',null,[r.ref]))
   continue
  }
  if(obs.proposalIdentity?.institutionKey==null)out.push(finding('ambiguous_identity','review',key,[r.ref],{reason:'institution_unknown'}))
  const g=groups.get(key)??[];g.push(r);groups.set(key,g)
 }
 for(const [key,g] of groups){
  if(g.length<2)continue
  // Replay: byte-identical normalized content from the same source is a no-op, never a new fact.
  const seen=new Map<string,ConflictRow>()
  const distinct:ConflictRow[]=[]
  for(const r of g){
   const sig=`${r.sourceId}|${rowContentHash(r)}`
   const prior=seen.get(sig)
   if(prior){
    out.push(finding(prior.batchId===r.batchId?'duplicate_in_batch':'replay','info',key,[prior.ref,r.ref],{contentSha256:rowContentHash(r)}))
   }else{seen.set(sig,r);distinct.push(r)}
  }
  if(distinct.length<2)continue
  const sources=new Set(distinct.map(r=>r.sourceId))
  if(sources.size>1)out.push(finding('multi_source_same_proposal','review',key,distinct.map(r=>r.ref),{sources:sources.size}))
  // Contradictory statuses: same dimension, different raw values. Kept independent per dimension.
  const byDim=new Map<string,Map<string,string[]>>()
  for(const r of distinct){
   for(const [dim,val] of Object.entries(statusMap(r))){
    const m=byDim.get(dim)??new Map<string,string[]>()
    m.set(val,[...(m.get(val)??[]),r.ref]);byDim.set(dim,m)
   }
  }
  for(const [dim,m] of byDim){
   if(m.size<2)continue
   const refs=[...m.values()].flat()
   const dated=distinct.filter(r=>r.occurredAt)
   const isCorrection=dated.length===distinct.length&&new Set(dated.map(r=>r.occurredAt)).size===dated.length
   out.push(finding(isCorrection?'later_correction':'contradictory_status','review',key,refs,{dimension:dim,values:[...m.keys()].sort()}))
  }
 }
 return out
}

// Whether a row may proceed without human review. Deliberately conservative.
export function requiresHumanReview(findings:ConflictFinding[],ref:string){
 return findings.some(f=>f.rowRefs.includes(ref)&&f.severity!=='info')
}
