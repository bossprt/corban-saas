'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { canManageMemberRole, canManageTeam } from '@/lib/rbac'
import { classifyTeamError, isUuid, normalizeEmail, type TeamErrorCode, type TeamOkCode } from '@/lib/team'
import { sendInvitationEmail } from '@/lib/team.server'

const back=(q:string):never=>redirect(`/app/equipe?${q}`)
const fail=(code:TeamErrorCode):never=>back(`erro=${code}`)
const done=(code:TeamOkCode):never=>{revalidatePath('/app/equipe');return back(`ok=${code}`)}
const text=(f:FormData,k:string)=>String(f.get(k)??'')

// The organization is ALWAYS the active one from the server context; a form field can never name a tenant.
export async function inviteMember(formData:FormData){
 const { supabase, membership, organization }=await requireAppContext()
 const email=normalizeEmail(text(formData,'email'))
 const role=text(formData,'role')
 if(!canManageTeam(membership.role))return fail('not_authorized')
 if(!email)return fail('invalid_email')
 if(!canManageMemberRole(membership.role,null,role))return fail('role_change_not_permitted')
 const { error }=await supabase.rpc('create_organization_invitation',{p_org:organization.id,p_email:email,p_role:role})
 if(error)return fail(classifyTeamError(error))
 const outcome=await sendInvitationEmail(email)
 return done(outcome==='sent'?'invited':outcome==='existing_user'?'invited_existing':'invited_no_email')
}

export async function resendInvitation(formData:FormData){
 const { supabase, membership }=await requireAppContext()
 const id=text(formData,'invitation_id')
 if(!isUuid(id))return fail('invalid_input')
 if(!canManageTeam(membership.role))return fail('not_authorized')
 // RLS: only managers of this organization can read the row; a foreign id simply is not found.
 const { data:inv }=await supabase.from('organization_invitations').select('email,role,status,expires_at').eq('id',id).maybeSingle()
 if(!inv)return fail('invitation_not_found')
 if(inv.status!=='pending'||new Date(inv.expires_at)<=new Date())return fail('invitation_already_resolved')
 if(!canManageMemberRole(membership.role,null,inv.role))return fail('not_authorized')
 const outcome=await sendInvitationEmail(inv.email)
 return outcome==='failed'?fail('unexpected'):done('resent')
}

export async function revokeInvitation(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'invitation_id')
 if(!isUuid(id))return fail('invalid_input')
 const { error }=await supabase.rpc('revoke_organization_invitation',{p_invitation_id:id})
 return error?fail(classifyTeamError(error)):done('revoked')
}

export async function changeMemberRole(formData:FormData){
 const { supabase }=await requireAppContext()
 const id=text(formData,'membership_id')
 if(!isUuid(id))return fail('invalid_input')
 const { error }=await supabase.rpc('set_member_role',{p_membership_id:id,p_role:text(formData,'role')})
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
