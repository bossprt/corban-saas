import type { ParsedImportRow } from './contract'
import { detectConflicts,type ConflictFinding,type ConflictKind,type ConflictRow } from './conflicts'

// Builds the payload for public.record_import_conflicts (20260919_import_conflicts_v1). Pure: no I/O, no tenant data
// beyond the batch's own rows. The database derives the tenant from the batch, validates that every referenced raw row
// belongs to it, and stores findings idempotently. A finding never publishes financial truth.

export type PersistedKind='duplicate_row'|'duplicate_file'|'multi_source_same_proposal'|'contradictory_status'|'ambiguous_identity'|'correction_replay'|'cross_tenant_attempt'|'unknown_schema'|'unresolved_matching'|'missing_identity'

const KIND_MAP:Record<ConflictKind,PersistedKind>={
 replay:'duplicate_row',
 duplicate_in_batch:'duplicate_row',
 multi_source_same_proposal:'multi_source_same_proposal',
 contradictory_status:'contradictory_status',
 later_correction:'correction_replay',
 ambiguous_identity:'ambiguous_identity',
 cross_tenant_rows:'cross_tenant_attempt',
 missing_identity:'missing_identity'
}

export type RpcFinding={kind:PersistedKind;severity:'info'|'review'|'block';identityKey:string|null;detail:Record<string,unknown>;rawRowIds:string[]}

const SCHEMA_REASONS=new Set(['empty_header','missing_proposal_identity_column','no_known_source_semantics_column'])

// rowIdByNumber: import_raw_rows.id per row_number of THIS batch (loaded through RLS after ingestion).
export function buildBatchFindings(rows:ParsedImportRow[],ctx:{organizationId:string;sourceId:string;providerKey:string|null;batchId:string},rowIdByNumber:Map<number,string>):RpcFinding[]{
 const out:RpcFinding[]=[]
 const idOf=(ref:string)=>rowIdByNumber.get(Number(ref))
 const conflictRows:ConflictRow[]=rows.map(r=>({ref:String(r.rowNumber),organizationId:ctx.organizationId,sourceId:ctx.sourceId,providerKey:ctx.providerKey,batchId:ctx.batchId,occurredAt:null,normalized:r.normalized}))
 const push=(f:ConflictFinding)=>{
  const ids=[...new Set(f.rowRefs.map(idOf).filter((x):x is string=>!!x))]
  if(!ids.length)return
  out.push({kind:KIND_MAP[f.kind],severity:f.severity,identityKey:f.identityKey,detail:f.detail,rawRowIds:ids})
 }
 for(const f of detectConflicts(conflictRows))push(f)
 // Unknown schema / rows without identity are surfaced from the adapter's quarantine marker, one finding per reason.
 const byReason=new Map<string,string[]>()
 for(const r of rows){
  const q=(r.normalized.normalizedPayload as {quarantine?:{reason?:string}|null}).quarantine
  const id=rowIdByNumber.get(r.rowNumber)
  if(q?.reason&&id)byReason.set(q.reason,[...(byReason.get(q.reason)??[]),id])
 }
 for(const [reason,ids] of byReason)out.push({kind:SCHEMA_REASONS.has(reason)?'unknown_schema':'missing_identity',severity:'review',identityKey:null,detail:{reason},rawRowIds:ids})
 return out
}
