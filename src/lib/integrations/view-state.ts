import { atLeast } from '../rbac'

// UI state model for integration runs. Pure, so every state the operator can see is testable and none is conflated with another:
// permission denied != unavailable (module/columns missing) != error != empty != data.
export type RunRow={
 id:string;status:'queued'|'running'|'succeeded'|'failed'|'cancelled';capability:string;attempt_count:number;max_attempts:number
 error_code:string|null;created_at:string;finished_at:string|null
 terminal?:boolean|null;next_attempt_at?:string|null;correlation_id?:string|null;updated_at?:string|null;parent_run_id?:string|null;reexecution_reason?:string|null
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

// ---- operator feedback for the governed actions (stable codes in the URL, human text on the page; never a raw RPC message)
export type RunFeedback='run_invalid'|'forbidden'|'run_not_found'|'reason_invalid'|'not_reexecutable'|'illegal_transition'|'unexpected'
export function classifyRunActionError(code:string|null|undefined):RunFeedback{
 switch(code){
  case'actor_not_authorized':return 'forbidden'
  case'run_not_found':case'binding_not_found':return 'run_not_found'
  case'parent_not_reexecutable':return 'not_reexecutable'
  case'illegal_integration_run_transition':return 'illegal_transition'
  case'reexecution_reason_length_invalid':case'secret_like_content':return 'reason_invalid'
  default:return 'unexpected'
 }
}
export const RUN_ERROR_MESSAGES:Record<RunFeedback,string>={
 run_invalid:'Execução inválida.',
 forbidden:'Seu perfil não tem permissão para esta ação.',
 run_not_found:'Execução não encontrada para a sua organização.',
 reason_invalid:'Informe um motivo entre 10 e 500 caracteres, sem credenciais.',
 not_reexecutable:'Só é possível criar nova execução a partir de uma execução com falha terminal ou cancelada. Se ainda há tentativas, use Nova tentativa.',
 illegal_transition:'O estado atual da execução não permite esta ação (ela pode ter mudado). Atualize a página.',
 unexpected:'Erro inesperado. Nada foi alterado; tente novamente.'
}
export const RUN_OK_MESSAGES:Record<string,string>={
 retry:'Passe de execução solicitado.',
 retry_not_due:'Esta execução ainda não está elegível (espera de nova tentativa, limite ou já em andamento). Nada foi executado.',
 cancelled:'Execução cancelada. O histórico foi mantido.',
 reexecuted:'Nova execução criada, ligada à original.'
}
export const isRunFeedback=(v:unknown):v is RunFeedback=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(RUN_ERROR_MESSAGES,v)
export const isRunOk=(v:unknown):v is string=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(RUN_OK_MESSAGES,v)

// Lineage among the rows on screen: original -> new execution. Ids only.
export function lineageOf(rows:readonly Pick<RunRow,'id'|'parent_run_id'>[]){
 const childOf=new Map<string,string>()
 for(const r of rows)if(r.parent_run_id)childOf.set(r.parent_run_id,r.id)
 return childOf
}
