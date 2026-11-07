import { PIPELINE_SITUATIONS, SITUATION_LABEL, SITUATION_NEXT, contractSituation, situationLabel } from './contractStatus'
// Maps the stable error tokens raised by transition_operational_case to operator-facing outcomes. The RPC message is never shown raw and
// never swallowed into a generic failure: the operator can tell "not allowed" from "invalid transition" from "someone else moved it".
export type OperationalErrorCode='invalid_transition'|'forbidden'|'case_unavailable'|'paid_requires_source'|'stage_not_configured'|'unexpected'

export function classifyTransitionError(message:string|null|undefined):OperationalErrorCode{
 const m=String(message??'')
 if(/invalid_operational_state_transition/.test(m))return 'invalid_transition'
 if(/operational_decision_requires_privileged_role|active_membership_required/.test(m))return 'forbidden'
 if(/operational_case_not_found_or_forbidden/.test(m))return 'case_unavailable'
 if(/paid_requires_confirmed_financial_source/.test(m))return 'paid_requires_source'
 if(/target_operational_stage_not_configured/.test(m))return 'stage_not_configured'
 return 'unexpected'
}

export const OPERATIONAL_MESSAGES:Record<OperationalErrorCode,string>={
 invalid_transition:'Transição inválida para o estado atual. O caso pode ter sido movido por outra pessoa: atualize a página e confira o estado.',
 forbidden:'Seu perfil não tem permissão para esta decisão operacional.',
 case_unavailable:'Caso não encontrado ou indisponível para a sua organização.',
 paid_requires_source:'Pago só é confirmado por evidência financeira governada, nunca pela esteira.',
 stage_not_configured:'A etapa de destino não está configurada para a organização.',
 unexpected:'Erro inesperado ao mover o caso. Nada foi alterado; tente novamente e, se persistir, avise o suporte.'
}

export const isOperationalErrorCode=(v:unknown):v is OperationalErrorCode=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(OPERATIONAL_MESSAGES,v)

// Operator-facing names for esteira states and the next step for each: the shared names (src/lib/contractStatus.ts).
export const CASE_STATE_LABEL:Record<string,{label:string;next:string}>=Object.fromEntries(PIPELINE_SITUATIONS.map(s=>[s,{label:SITUATION_LABEL[s],next:SITUATION_NEXT[s]}]))
export const caseStateLabel=(s:string)=>CASE_STATE_LABEL[s]??{label:'Situação desconhecida',next:''}
export const JOB_STATUS_LABEL:Record<string,string>={queued:'Na fila',assigned:'Atribuída',in_progress:'Em andamento',blocked:'Bloqueada',submitted:'Enviada',completed:'Concluída',cancelled:'Cancelada'}
export const jobStatusLabel=(s:string)=>JOB_STATUS_LABEL[s]??'Situação desconhecida'

// Operator-facing proposal status and the next step, from the shared names. Pass the pipeline case state when known:
// the proposal status alone cannot tell "Aguardando digitação" from "Em digitação".
export function proposalStatusLabel(status:string,caseState?:string|null,paidSource?:string|null):{label:string;next:string}{
 const s=contractSituation(status,caseState)
 return {label:situationLabel(s,{paidSource}),next:s?SITUATION_NEXT[s]:''}
}
