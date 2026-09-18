// Single application-level RBAC policy. The database (RLS + RPC role checks) stays the authority; this mirrors it
// so UI and server actions fail early and consistently. Unknown/missing roles are denied (fail closed).
export type Role='agent'|'supervisor'|'manager'|'admin'

const RANK:Record<Role,number>={agent:1,supervisor:2,manager:3,admin:4}

export function atLeast(role:string|null|undefined,min:Role):boolean{
 if(!role||!Object.prototype.hasOwnProperty.call(RANK,role))return false
 return RANK[role as Role]>=RANK[min]
}
