const SCALE=BigInt(100000000)
const HUNDRED=BigInt(100)*SCALE

const scaled=(raw:string):bigint=>{
  const v=String(raw??'').trim()
  if(!/^\d+(?:\.\d{1,8})?$/.test(v))throw new Error('invalid_decimal')
  const [i,f='']=v.split('.')
  return BigInt(i)*SCALE+BigInt((f+'00000000').slice(0,8))
}
const text=(v:bigint):string=>{
  const sign=v<BigInt(0)?'-':''
  const a=v<BigInt(0)?-v:v
  const i=a/SCALE
  const f=String(a%SCALE).padStart(8,'0').replace(/0+$/,'')
  return sign+String(i)+(f?'.'+f:'')
}
const pct=(value:bigint,percentage:string):bigint=>(value*scaled(percentage)+HUNDRED/2n)/HUNDRED

export type ComponentEconomicsInput={
  receivedValue:string
  receivedKind:'percentage'|'fixed_brl'
  discountPct:string
  mode:'share_of_received'|'direct'|'exclude'
  sharePct?:string|null
  directValueKind?:'percentage'|'fixed_brl'|null
  directValue?:string|null
}
export type ComponentEconomicsResult={
  gross:string
  net:string
  payout:string
  retained:string|null
  payoutKind:'percentage'|'fixed_brl'|null
  compatible:boolean
}

export function componentEconomics(x:ComponentEconomicsInput):ComponentEconomicsResult{
  const gross=scaled(x.receivedValue)
  const discount=scaled(x.discountPct||'0')
  if(discount<BigInt(0)||discount>HUNDRED)throw new Error('invalid_discount')
  const net=(gross*(HUNDRED-discount)+HUNDRED/2n)/HUNDRED
  if(x.mode==='exclude'){
    return {gross:text(gross),net:text(net),payout:'0',retained:text(net),payoutKind:x.receivedKind,compatible:true}
  }
  if(x.mode==='share_of_received'){
    if(x.sharePct==null)throw new Error('missing_share')
    const repass=pct(net,x.sharePct)
    return {gross:text(gross),net:text(net),payout:text(repass),retained:text(net-repass),payoutKind:x.receivedKind,compatible:true}
  }
  if(!x.directValueKind||x.directValue==null)throw new Error('missing_direct')
  const direct=scaled(x.directValue)
  const compatible=x.directValueKind===x.receivedKind
  return {gross:text(gross),net:text(net),payout:text(direct),retained:compatible?text(net-direct):null,payoutKind:x.directValueKind,compatible}
}
