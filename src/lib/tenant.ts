// Active-tenant resolution for users that may belong to several organizations.
// Rules: never pick an organization implicitly. With exactly one active membership the tenant is that one; with several,
// the tenant is the one explicitly selected (cookie) AND still present in the user's ACTIVE memberships (re-validated on
// every request, so a revoked membership or a forged cookie can never select a tenant). Otherwise the user must choose.

export const ACTIVE_ORG_COOKIE='corban_org'

export type MembershipRow={organization_id:string;role:string}
export type TenantResolution=
 |{kind:'none'}
 |{kind:'active';membership:MembershipRow}
 |{kind:'choose';memberships:MembershipRow[]}

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function resolveActiveMembership(memberships:MembershipRow[],cookieValue:string|null|undefined):TenantResolution{
 const unique=[...new Map(memberships.map(m=>[m.organization_id,m])).values()]
 if(unique.length===0)return {kind:'none'}
 if(unique.length===1)return {kind:'active',membership:unique[0]}
 const wanted=cookieValue&&UUID.test(cookieValue)?cookieValue.toLowerCase():null
 const hit=wanted?unique.find(m=>m.organization_id.toLowerCase()===wanted):undefined
 return hit?{kind:'active',membership:hit}:{kind:'choose',memberships:unique}
}

// Tables without an organization_id column (global catalogs / tenants themselves). Every other table is tenant-scoped.
export const TENANT_FREE_TABLES=new Set(['agreements','banks','contract_types','document_types','integration_adapters','integration_field_mappings','modalities','national_agreement_templates','organizations','platform_administrators','products','providers'])

type Chainable={eq:(column:string,value:unknown)=>unknown}

// Wraps a Supabase client so that select/update/delete on tenant-scoped tables are ALWAYS filtered to the active
// organization. RLS still allows every organization the user belongs to; without this a multi-org user would see a mix.
// rpc() is untouched: RPCs derive the tenant from the resource they operate on.
export function scopeToOrganization<T extends object>(client:T,organizationId:string):T{
 const c=client as unknown as {from:(table:string)=>Record<string,unknown>}
 const scopedFrom=(table:string)=>{
  const builder=c.from(table)
  if(TENANT_FREE_TABLES.has(table))return builder
  return new Proxy(builder,{
   get(target,prop,receiver){
    const value=Reflect.get(target,prop,receiver)
    if(typeof value!=='function')return value
    if(prop==='select'||prop==='update'||prop==='delete'){
     return (...args:unknown[])=>((value as (...a:unknown[])=>Chainable).apply(target,args)).eq('organization_id',organizationId)
    }
    return value.bind(target)
   }
  })
 }
 return new Proxy(client,{
  get(target,prop,receiver){
   if(prop==='from')return scopedFrom
   const value=Reflect.get(target,prop,receiver)
   return typeof value==='function'?value.bind(target):value
  }
 })
}
