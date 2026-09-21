
const SCALE=BigInt(100000000)
const HUNDRED=BigInt(100)*SCALE

function scaled8(raw:string):bigint{
 const v=String(raw??'').trim()
 if(!/^\d+(?:\.\d{1,8})?$/.test(v))throw new Error('invalid_decimal')
 const [i,f='']=v.split('.')
 return BigInt(i)*SCALE+BigInt((f+'00000000').slice(0,8))
}
function fromScaled8(v:bigint):string{
 const sign=v<0n?'-':''
 const a=v<0n?-v:v
 const i=a/SCALE
 const f=String(a%SCALE).padStart(8,'0').replace(/0+$/,'')
 return sign+String(i)+(f?'.'+f:'')
}
function mulPct(value:bigint,pct:string):bigint{
 return (value*scaled8(pct)+HUNDRED/2n)/HUNDRED
}

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
 const gross=scaled8(x.receivedValue)
 const discount=scaled8(x.discountPct||'0')
 if(discount<0n||discount>HUNDRED)throw new Error('invalid_discount')
 const net=(gross*(HUNDRED-discount)+HUNDRED/2n)/HUNDRED
 if(x.mode==='exclude')return {gross:fromScaled8(gross),net:fromScaled8(net),payout:'0',retained:fromScaled8(net),payoutKind:x.receivedKind,compatible:true}
 if(x.mode==='share_of_received'){
  if(x.sharePct==null)throw new Error('missing_share')
  const payout=mulPct(net,x.sharePct)
  return {gross:fromScaled8(gross),net:fromScaled8(net),payout:fromScaled8(payout),retained:fromScaled8(net-payout),payoutKind:x.receivedKind,compatible:true}
 }
 if(!x.directValueKind||x.directValue==null)throw new Error('missing_direct')
 const direct=scaled8(x.directValue)
 const compatible=x.directValueKind===x.receivedKind
 return {
  gross:fromScaled8(gross),net:fromScaled8(net),payout:fromScaled8(direct),
  retained:compatible?fromScaled8(net-direct):null,payoutKind:x.directValueKind,compatible
 }
}
