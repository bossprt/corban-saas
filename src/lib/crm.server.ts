import 'server-only'
import type { SupabaseClient } from '@supabase/supabase-js'
import { memberEmails } from '@/lib/team.server'

// Active members whose role can work leads (leads.edit, or an admin role): the people a campaign or a lead can go to.
// The database checks the same rule again (private.can_own_leads) on every assignment.
export async function leadOwners(supabase: SupabaseClient): Promise<{ id: string; name: string }[]> {
  const [{ data: members }, { data: roles }] = await Promise.all([
    supabase.from('organization_memberships').select('user_id,role_id').eq('status', 'active'),
    supabase.from('organization_roles').select('id,tier,permissions,is_active'),
  ])
  const ok = new Set((roles ?? []).filter(r => r.is_active && (r.tier === 'admin' || (r.permissions ?? []).includes('leads.edit'))).map(r => r.id))
  const ids = (members ?? []).filter(m => ok.has(m.role_id)).map(m => m.user_id as string)
  const emails = await memberEmails(ids)
  return ids.map(id => ({ id, name: emails.get(id) ?? 'Usuário' })).sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'))
}
