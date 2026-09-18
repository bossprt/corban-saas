import { add,cmp,div,fromDecimalString,isZero,mul,sub,toDecimalString } from './money'

// Deterministic expected-commission calculator. It mirrors public.publish_expected_commission (SQL) so the UI can
// preview and tests can cross-check the same rules. It PUBLISHES nothing: expected commission is an expectation, never
// received revenue, and only the governed SQL publisher writes ledger events.
// Rules mirrored from SQL:
//  gross = fixed_amount, or base * gross_percentage / 100        (fixed wins when both are present)
//  deferred_anticipation: gross *= anticipation_factor (factor required)
//  tenant = gross * upstream_share ; downstream = gross - tenant
// A component whose value is ZERO is a real, reported zero commission and is still emitted; only a component with
// neither fixed amount nor percentage (unknown) is an error. Blank is never treated as zero.

export type ComponentInput={
 componentType:'upfront'|'deferred'|'deferred_anticipation'|'campaign_bonus'|'volume_bonus'|'fixed'|'other'
 fixedAmount:string|null
 grossPercentage:string|null
 anticipationFactor:string|null
 upstreamShare:string
}

export type ComponentResult={componentType:ComponentInput['componentType'];gross:string;tenant:string;downstream:string}

const ZERO=fromDecimalString('0')
const ONE=fromDecimalString('1')

export function calculateExpectedCommission(calculationBase:string,components:ComponentInput[],scale=2):ComponentResult[]{
 const base=fromDecimalString(calculationBase)
 if(base.n<BigInt(0))throw new Error('snapshot_calculation_base_required')
 if(!components.length)throw new Error('per_component_snapshot_required')
 return components.map(c=>{
  if(c.fixedAmount===null&&c.grossPercentage===null)throw new Error('component_value_required')
  let gross=c.fixedAmount!==null?fromDecimalString(c.fixedAmount):div(mul(base,fromDecimalString(c.grossPercentage as string)),fromDecimalString('100'))
  if(c.componentType==='deferred_anticipation'){
   if(c.anticipationFactor===null)throw new Error('anticipation_factor_required')
   gross=mul(gross,fromDecimalString(c.anticipationFactor))
  }
  const share=fromDecimalString(c.upstreamShare)
  if(cmp(share,ZERO)<0||cmp(share,ONE)>0)throw new Error('invalid_share')
  const tenant=mul(gross,share)
  const downstream=sub(gross,tenant)
  // exactness invariant: the two parts always sum back to the gross amount
  if(!isZero(sub(add(tenant,downstream),gross)))throw new Error('split_invariant_violated')
  return {componentType:c.componentType,gross:toDecimalString(gross,scale),tenant:toDecimalString(tenant,scale),downstream:toDecimalString(downstream,scale)}
 })
}
