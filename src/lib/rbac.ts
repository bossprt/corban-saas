// Single application-level RBAC policy. The database (RLS + RPC role checks) stays the authority; this mirrors it
// so UI and server actions fail early and consistently. Unknown/missing roles are denied (fail closed).
export type Role='agent'|'supervisor'|'manager'|'admin'

const RANK:Record<Role,number>={agent:1,supervisor:2,manager:3,admin:4}

export function atLeast(role:string|null|undefined,min:Role):boolean{
 if(!role||!Object.prototype.hasOwnProperty.call(RANK,role))return false
 return RANK[role as Role]>=RANK[min]
}

// Team administration. MUST stay identical to public.can_manage_member_role (migration 20260925_team_access_lifecycle_v1); a unit test pins the matrix.
// admin manages everyone; manager manages only supervisor/agent (as current AND new role); nobody else manages anyone. `current` is null for a new invitation.
const ROLES:readonly Role[]=['agent','supervisor','manager','admin']
const isRole=(r:string|null|undefined):r is Role=>!!r&&Object.prototype.hasOwnProperty.call(RANK,r)
export function canManageMemberRole(actor:string|null|undefined,current:string|null|undefined,next:string|null|undefined):boolean{
 if(!isRole(next)||(current!=null&&!isRole(current)))return false
 if(actor==='admin')return true
 if(actor==='manager')return (next==='supervisor'||next==='agent')&&(current==null||current==='supervisor'||current==='agent')
 return false
}
export const rolesAssignableBy=(actor:string|null|undefined):Role[]=>ROLES.filter(r=>canManageMemberRole(actor,null,r))
export const canManageTeam=(role:string|null|undefined)=>atLeast(role,'manager')

// Commission rates of the tables (what the bank pays the company): supervisor and above only. Owner decision (ADR-0031):
// a seller sees only their own share, on their own proposals, through proposal_commission_mine; never the company's rates.
export const canViewCommission=(role:string|null|undefined)=>atLeast(role,'supervisor')
