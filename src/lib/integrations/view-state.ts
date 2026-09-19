import { atLeast } from '../rbac'

// UI state model for integration runs. Pure, so every state the operator can see is testable and none is conflated with another:
// permission denied != unavailable (module/columns missing) != error != empty != data.
export type RunRow={
 id:string;status:'queued'|'running'|'succeeded'|'failed'|'cancelled';capability:string;attempt_count:number;max_attempts:number
 error_code:string|null;created_at:string;finished_at:string|null
 terminal?:boolean|null;next_attempt_at?:string|null;correlation_id?:string|null;updated_at?:string|null;parent_run_id?:string|null
 adapter?:{adapter_key:string}|{adapter_key:string}[]|null
}
export type RunsView=
 |{kind:'permission_denied'}
 |{kind:'unavailable'}
 |{kind:'error'}
 |{kind:'empty'}
 |{kind:'ready';rows:RunRow[]}

const MISSING_CODES=['42P01','42703','PGRST205','PGRST204']

export function classifyRunsView(input:{role:string|null|undefined;error:{code?:string}|null;rows:RunRow[]|null}):RunsView{
 // Authorization is decided BEFORE looking at data: an agent gets an explicit denial, not a misleading "empty".
 if(!atLeast(input.role,'supervisor'))return {kind:'permission_denied'}
 if(input.error){
  return MISSING_CODES.includes(String(input.error.code))?{kind:'unavailable'}:{kind:'error'}
 }
 return input.rows&&input.rows.length?{kind:'ready',rows:input.rows}:{kind:'empty'}
}

export type RunPhase='queued'|'processing'|'completed'|'retry_scheduled'|'needs_human'|'cancelled'
// A terminally failed run is NOT silently retried: it waits for a human decision (fix the cause, then a new governed request).
export function runPhase(r:Pick<RunRow,'status'|'terminal'|'attempt_count'|'max_attempts'>):RunPhase{
 switch(r.status){
  case'queued':return 'queued'
  case'running':return 'processing'
  case'succeeded':return 'completed'
  case'cancelled':return 'cancelled'
  case'failed':return r.terminal||r.attempt_count>=r.max_attempts?'needs_human':'retry_scheduled'
 }
}
export const PHASE_LABEL:Record<RunPhase,string>={queued:'Na fila',processing:'Processando',completed:'Concluído',retry_scheduled:'Nova tentativa agendada',needs_human:'Aguardando ação humana',cancelled:'Cancelado'}

// Which governed actions the UI may OFFER. This mirrors the database (claim: supervisor+, cancel / re-execution: manager+) and is not
// a security boundary: every action goes through a server action and the worker functions re-check membership and role.
//  - RETRY ("Nova tentativa"): the SAME run continues; the database still enforces backoff, attempts and lease.
//  - REEXECUTION ("Nova execução"): a NEW run linked to a terminal parent; the parent history is never changed.
export type RunActions={retry:boolean;cancel:boolean;reexecute:boolean}
export function allowedActions(role:string|null|undefined,r:Pick<RunRow,'status'|'terminal'|'attempt_count'|'max_attempts'>):RunActions{
 const phase=runPhase(r)
 return {
  retry:atLeast(role,'supervisor')&&(phase==='retry_scheduled'||phase==='queued'),
  cancel:atLeast(role,'manager')&&(phase==='queued'||phase==='retry_scheduled'),
  reexecute:atLeast(role,'manager')&&(phase==='needs_human'||phase==='cancelled')
 }
}
