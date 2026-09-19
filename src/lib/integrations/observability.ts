import { redactMessage } from './redact'

// Minimal, safe execution telemetry. The event shape is a WHITELIST: request payloads, provider responses and headers can never be
// logged because there is no field for them. Free text (error message) always passes through the redactor.
export type ExecEvent={
 event:'run_claimed'|'run_refused'|'run_replayed'|'run_in_progress'|'provider_called'|'run_succeeded'|'run_failed'|'run_retry_scheduled'|'run_lease_lost'|'run_duplicate_result'|'repository_error'
 level:'info'|'warn'|'error'
 correlationId:string
 runId?:string
 provider:string
 adapter:string
 capability:string
 attempt?:number
 durationMs?:number
 outcome?:string
 errorCode?:string
 errorMessage?:string
}
export interface RunLogger{log(e:ExecEvent):void}

const FIELDS:(keyof ExecEvent)[]=['event','level','correlationId','runId','provider','adapter','capability','attempt','durationMs','outcome','errorCode','errorMessage']

export function sanitizeEvent(e:ExecEvent):Record<string,unknown>{
 const out:Record<string,unknown>={}
 for(const k of FIELDS){
  const v=(e as Record<string,unknown>)[k]
  if(v===undefined)continue
  out[k]=k==='errorMessage'?redactMessage(v,300):typeof v==='string'?redactMessage(v,200):v
 }
 return out
}

export class MemoryLogger implements RunLogger{
 readonly events:Record<string,unknown>[]=[]
 log(e:ExecEvent){this.events.push(sanitizeEvent(e))}
}
export const consoleLogger:RunLogger={log:e=>console.log(JSON.stringify({ts:new Date().toISOString(),...sanitizeEvent(e)}))}
export const nullLogger:RunLogger={log:()=>undefined}
