'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { canManageMemberRole, canManageTeam } from '@/lib/rbac'
import { classifyTeamError, isUuid, normalizeEmail, type TeamErrorCode, type TeamOkCode } from '@/lib/team'
import { createMemberLogin, setMemberPassword } from '@/lib/team.server'

const back=(q:string):never=>redirect(`/app/equipe?${q}`)
const fail=(code:TeamErrorCode):never=>back(`erro=${code}`)
const done=(code:TeamOkCode):never=>{revalidatePath('/app/equipe');return back(`ok=${code}`)}
const text=(f:FormData,k:string)=>String(f.get(k)??'')

// The organization is ALWAYS the active one from the server context; a form field can never name a tenant.
// Access is created by the admin with e-mail and password (owner decision 29/09/2026): no e-mail, no pending sign-up.
const PASSWORD_MIN=10, PASSWORD_MAX=72
const passwordOf=(f:FormData):string|null=>{
 const p=text(f,'password'), c=text(f,'password_confirm')
 return p.length>=PASSWORD_MIN&&p.length<=PASSWORD_MAX&&p===c?p:null
}

export async function createMemberAccess(formData:FormData){
 const { supabase, membership, organization }=await requireAppContext()
 const email=normalizeEmail(text(formData,'email'))
 const role=text(formData,'role')
 const mustChange=formData.get('must_change')==='on'
 if(!canManageTeam(membership.role))return fail('not_authorized')
 if(!email)return fail('invalid_email')
 if(!canManageMemberRole(membership.role,null,role))return fail('role_change_not_permitted')
 const password=passwordOf(formData)
 if(!password)return fail('invalid_password')
 const { data,error }=await supabase.rpc('prepare_member_access',{p_org:organization.id,p_email:email,p_role:role})
 if(error)return fail(classifyTeamError(error))
 const row=Array.isArray(data)?data[0]:null
 if(!row)return fail('unexpected')
 const outcome=await createMemberLogin(email,password,row.existing_user_id??null,mustChange)
 return outcome==='created'?done(mustChange?'access_created_change':'access_created'):fail('access_not_created')
}

export async function resetMemberPassword(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'membership_id')
 if(!isUuid(id))return fail('invalid_input')
 const password=passwordOf(formData)
 if(!password)return fail('invalid_password')
 const mustChange=formData.get('must_change')==='on'
 const { data:userId,error }=await supabase.rpc('authorize_member_password',{p_membership_id:id})
 if(error||!isUuid(userId))return fail(classifyTeamError(error))
 if(!(await setMemberPassword(userId,password,mustChange)))return fail('unexpected')
 await supabase.rpc('record_member_password_set',{p_membership_id:id,p_must_change:mustChange})
 return done(mustChange?'password_set_change':'password_set')
}

export async function revokeInvitation(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'invitation_id')
 if(!isUuid(id))return fail('invalid_input')
 const { error }=await supabase.rpc('revoke_organization_invitation',{p_invitation_id:id})
 return error?fail(classifyTeamError(error)):done('revoked')
}

// Assigns one of the company's roles (system or custom). The database checks the actor against the role's tier.
export async function changeMemberRole(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'membership_id')
 const roleId=text(formData,'role_id')
 if(!isUuid(id)||!isUuid(roleId))return fail('invalid_input')
 const { error }=await supabase.rpc('assign_member_access_role',{p_membership_id:id,p_role_id:roleId})
 return error?fail(classifyTeamError(error)):done('role_changed')
}

export async function changeMemberStatus(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'membership_id')
 const status=text(formData,'status')
 if(!isUuid(id))return fail('invalid_input')
 const { error }=await supabase.rpc('set_member_status',{p_membership_id:id,p_status:status})
 return error?fail(classifyTeamError(error)):done('status_changed')
}

// Branch, team leader and per-person scope exception. Empty fields clear the value (scope then follows the role).
export async function changeMemberHierarchy(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'membership_id')
 const branch=text(formData,'branch_id')
 const leader=text(formData,'team_leader_user_id')
 const scope=text(formData,'scope_override')
 if(!isUuid(id)||(branch&&!isUuid(branch))||(leader&&!isUuid(leader))||(scope&&!['own','team','branch','all'].includes(scope)))return fail('invalid_input')
 const { error }=await supabase.rpc('set_member_hierarchy',{p_membership_id:id,p_branch_id:branch||null,p_team_leader_user_id:leader||null,p_scope_override:scope||null})
 return error?fail(classifyTeamError(error)):done('hierarchy_changed')
}
