import 'server-only'
import { siteOrigin } from '@/lib/site-origin'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { isExistingUserError } from '@/lib/team'

// Server-only identity plumbing for the team module. The service role never leaves the server and is used for exactly three things:
// (1) asking Supabase Auth to send the invitation e-mail, (2) reading member e-mail addresses for display, (3) the service_role-only
// accept RPC. Authorization ALWAYS happens before, with the caller's own session (RLS + governed RPCs).

export type InviteEmailOutcome='sent'|'existing_user'|'failed'
export async function sendInvitationEmail(email:string):Promise<InviteEmailOutcome>{
 try{
  const origin=await siteOrigin()
  const { error }=await createAdminClient().auth.admin.inviteUserByEmail(email,origin?{redirectTo:`${origin}/auth/definir-senha`}:undefined)
  if(!error)return 'sent'
  return isExistingUserError(error)?'existing_user':'failed'
 }catch{return 'failed'}
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
