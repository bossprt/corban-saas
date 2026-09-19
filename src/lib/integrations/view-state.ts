import { atLeast } from '../rbac'

// UI state model for integration runs. Pure, so every state the operator can see is testable and none is conflated with another:
// permission denied != unavailable (module/columns missing) != error != empty != data.
export type RunRow={
 id:string;status:'queued'|'running'|'succeeded'|'failed'|'cancelled';capability:string;attempt_count:number;max_attempts:number
 error_code:string|null;created_at:string;finished_at:string|null
 terminal?:boolean|null;next_attempt_at?:string|null;correlation_id?:string|null
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

export type RunPhase='processing'|'completed'|'retry_scheduled'|'needs_human'|'cancelled'
// A terminally failed run is NOT silently retried: it waits for a human decision (fix the cause, then a new governed request).
export function runPhase(r:Pick<RunRow,'status'|'terminal'|'attempt_count'|'max_attempts'>):RunPhase{
 switch(r.status){
  case'queued':case'running':return 'processing'
  case'succeeded':return 'completed'
  case'cancelled':return 'cancelled'
  case'failed':return r.terminal||r.attempt_count>=r.max_attempts?'needs_human':'retry_scheduled'
 }
}
export const PHASE_LABEL:Record<RunPhase,string>={processing:'Processando',completed:'Concluído',retry_scheduled:'Nova tentativa agendada',needs_human:'Aguardando ação humana',cancelled:'Cancelado'}
