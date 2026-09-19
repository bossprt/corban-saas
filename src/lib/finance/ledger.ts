import { add,cmp,fromDecimalString,sub,toDecimalString,type Rational } from '../commission/money'

// Pure read-model of the append-only financial ledger. It mirrors public.refresh_financial_reconciliation:
//  expected = commission_expected  - reversals of commission_expected
//  reported = commission_reported  - reversals of commission_reported
//  settled  = payment_received     - reversals of payment_received
// A reversal never mutates the original; it is a compensating event. Amounts must arrive as decimal STRINGS
// (query with `amount_text:amount::text`) so money never passes through a JS float.

export type LedgerEvent={
 id:string
 event_type:string
 component_type:string|null
 amount_text:string
 currency:string
 occurred_at:string
 created_at:string
 source_kind:string
 source_reference:string|null
 reverses_event_id:string|null
 metadata?:Record<string,unknown>|null
}

export type LedgerEntry={
 original:LedgerEvent
 reversals:LedgerEvent[]
 reversedTotal:string
 net:string
 remainingReversible:string
}

export type Ledger={entries:LedgerEntry[];orphanReversals:LedgerEvent[];ungoverned:LedgerEvent[]}

const ZERO=fromDecimalString('0')
const GOVERNED=new Set(['commission_expected','commission_reported','payment_received','downstream_paid','network_share_expected','bonus_expected','downstream_payable'])
const byTime=(a:LedgerEvent,b:LedgerEvent)=>a.created_at===b.created_at?a.id.localeCompare(b.id):a.created_at<b.created_at?-1:1

export function buildLedger(events:LedgerEvent[]):Ledger{
 const sorted=[...events].sort(byTime)
 const originals=sorted.filter(e=>GOVERNED.has(e.event_type))
 const revs=sorted.filter(e=>e.event_type==='reversal')
 const ungoverned=sorted.filter(e=>!GOVERNED.has(e.event_type)&&e.event_type!=='reversal')
 const known=new Set(originals.map(e=>e.id))
 const orphanReversals=revs.filter(r=>!r.reverses_event_id||!known.has(r.reverses_event_id))
 const entries=originals.map(o=>{
  const mine=revs.filter(r=>r.reverses_event_id===o.id)
  const reversed=mine.reduce((s,r)=>add(s,fromDecimalString(r.amount_text)),ZERO)
  const amount=fromDecimalString(o.amount_text)
  return {original:o,reversals:mine,reversedTotal:toDecimalString(reversed,2),net:toDecimalString(sub(amount,reversed),2),remainingReversible:toDecimalString(sub(amount,reversed),2)}
 })
 return {entries,orphanReversals,ungoverned}
}

export type Buckets={expected:string;reported:string;settled:string;downstreamPaid:string;difference:string}

const BUCKET_OF:Record<string,keyof Omit<Buckets,'difference'>>={commission_expected:'expected',commission_reported:'reported',payment_received:'settled',downstream_paid:'downstreamPaid'}

// `difference` = settled - expected, the same convention as the generated column divergence_amount when settled exists.
export function bucketTotals(ledger:Ledger):Buckets{
 const acc:Record<string,Rational>={expected:ZERO,reported:ZERO,settled:ZERO,downstreamPaid:ZERO}
 for(const e of ledger.entries){
  const key=BUCKET_OF[e.original.event_type]
  if(key)acc[key]=add(acc[key],fromDecimalString(e.net))
 }
 if(cmp(acc.expected,ZERO)<0||cmp(acc.reported,ZERO)<0||cmp(acc.settled,ZERO)<0)throw new Error('ledger_negative_bucket')
 return {expected:toDecimalString(acc.expected,2),reported:toDecimalString(acc.reported,2),settled:toDecimalString(acc.settled,2),downstreamPaid:toDecimalString(acc.downstreamPaid,2),difference:toDecimalString(sub(acc.settled,acc.expected),2)}
}

export const EVENT_LABEL:Record<string,string>={
 commission_expected:'Comissão esperada',commission_reported:'Comissão reportada',payment_received:'Pagamento recebido',
 downstream_paid:'Repasse pago à rede',network_share_expected:'Repasse esperado',bonus_expected:'Bônus esperado',downstream_payable:'Repasse a pagar',reversal:'Reversão'
}

// Display only: groups a plain decimal string as pt-BR currency without converting to a float.
export function formatBRL(v:string|null|undefined):string{
 if(v==null||v==='')return '—'
 const m=/^(-?)(\d+)(?:\.(\d+))?$/.exec(v.trim())
 if(!m)return '—'
 const int=m[2].replace(/\B(?=(\d{3})+(?!\d))/g,'.')
 const frac=(m[3]??'').padEnd(2,'0')
 return `${m[1]?'-':''}R$ ${int},${frac}`
}
