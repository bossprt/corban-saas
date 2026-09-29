import 'server-only'
import { createAdminClient } from '@/lib/supabaseAdmin'

// Server-only identity plumbing for the team module. The service role never leaves the server and is used for: (1) creating or
// completing a login with the password the manager typed, and setting a member's password, (2) reading member e-mail addresses
// for display, (3) the service_role-only accept RPC. Authorization ALWAYS happens before, with the caller's own session (RLS +
// governed RPCs).

// Access created by the admin with a password (owner decision 29/09/2026). Called only after public.prepare_member_access,
// with the manager's session, allowed it (role, company, and an e-mail that reaches nothing outside this company). The
// login is created, or completed when it already exists only for this company, confirmed, and the invitation is accepted at
// once. `mustChange` makes the person choose their own password on the first entry. The password is never logged.
export type AccessOutcome='created'|'failed'
export async function createMemberLogin(email:string,password:string,existingUserId:string|null,mustChange:boolean):Promise<AccessOutcome>{
 try{
  const admin=createAdminClient()
  const app_metadata={must_change_password:mustChange}
  let userId=existingUserId
  if(userId){
   const { error }=await admin.auth.admin.updateUserById(userId,{password,email_confirm:true,app_metadata})
   if(error)return 'failed'
  }else{
   const { data,error }=await admin.auth.admin.createUser({email,password,email_confirm:true,app_metadata})
   if(error||!data.user)return 'failed'
   userId=data.user.id
  }
  const { data:joined,error }=await admin.rpc('accept_organization_invitations',{p_user_id:userId,p_email:email})
  if(error||!Array.isArray(joined)||!joined.length)return 'failed'
  return 'created'
 }catch{return 'failed'}
}

// New password for a member, after public.authorize_member_password allowed it for the caller.
export async function setMemberPassword(userId:string,password:string,mustChange:boolean):Promise<boolean>{
 try{
  const { error }=await createAdminClient().auth.admin.updateUserById(userId,{password,app_metadata:{must_change_password:mustChange}})
  return !error
 }catch{return false}
}

// The person chose their own password: the first-entry requirement is cleared (identity from Auth, never from the form).
export async function clearMustChangePassword(userId:string):Promise<boolean>{
 try{
  const { error }=await createAdminClient().auth.admin.updateUserById(userId,{app_metadata:{must_change_password:false}})
  return !error
 }catch{return false}
}

// Accepts every pending, unexpired invitation addressed to the VERIFIED e-mail of the signed-in user. The identity comes from
// supabase.auth.getUser() (validated by Auth, not from a cookie claim); an unconfirmed address never accepts anything.
export async function acceptInvitationsFor(user:{id:string;email?:string|null;email_confirmed_at?:string|null}):Promise<number>{
 if(!user.email||!user.email_confirmed_at)return 0
 try{
  const { data,error }=await createAdminClient().rpc('accept_organization_invitations',{p_user_id:user.id,p_email:user.email})
  if(error)return 0
  return Array.isArray(data)?data.filter((r:{outcome:string})=>r.outcome==='joined'||r.outcome==='reactivated').length:0
 }catch{return 0}
}

// Display only: e-mail addresses of users whose membership rows the caller can already read (RLS decided that).
export async function memberEmails(userIds:string[]):Promise<Map<string,string>>{
 const out=new Map<string,string>()
 const admin=createAdminClient()
 await Promise.all([...new Set(userIds)].slice(0,200).map(async id=>{
  try{const { data }=await admin.auth.admin.getUserById(id);if(data.user?.email)out.set(id,data.user.email)}catch{/* leave unresolved */}
 }))
 return out
}
