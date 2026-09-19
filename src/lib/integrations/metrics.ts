// Pure derivation of operational metrics from the sanitized event stream (no external service). Feed it the events a log sink kept.
export type MetricEvent={event?:unknown;durationMs?:unknown;outcome?:unknown;attempt?:unknown}
export type RunMetrics={
 claimed:number;succeeded:number;failedTerminal:number;retryScheduled:number;leaseTakeovers:number;leaseLost:number
 successRate:number|null;retryRate:number|null;latencyP50Ms:number|null;latencyP95Ms:number|null
}
const pct=(sorted:number[],p:number)=>sorted.length?sorted[Math.min(sorted.length-1,Math.ceil(p*sorted.length)-1)]:null

export function computeRunMetrics(events:readonly MetricEvent[]):RunMetrics{
 const c=(name:string)=>events.filter(e=>e.event===name).length
 const claimed=c('run_claimed'),succeeded=c('run_succeeded'),failedTerminal=c('run_failed'),retryScheduled=c('run_retry_scheduled')
 const takeovers=events.filter(e=>e.event==='run_claimed'&&e.outcome==='takeover').length
 const lat=events.filter(e=>e.event==='provider_called'&&typeof e.durationMs==='number').map(e=>e.durationMs as number).sort((a,b)=>a-b)
 const finished=succeeded+failedTerminal
 return {claimed,succeeded,failedTerminal,retryScheduled,leaseTakeovers:takeovers,leaseLost:c('run_lease_lost'),
  successRate:finished?succeeded/finished:null,retryRate:claimed?retryScheduled/claimed:null,latencyP50Ms:pct(lat,0.5),latencyP95Ms:pct(lat,0.95)}
}
