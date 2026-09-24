'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { isPermission, isScope } from '@/lib/access'
import { classifyTeamError, isUuid, type TeamErrorCode } from '@/lib/team'

const back = (q: string): never => redirect(`/app/configuracao/papeis?${q}`)
const fail = (code: TeamErrorCode): never => back(`erro=${code}`)
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()

// Creates or updates a role. The organization is always the active one; the database accepts it only from an administrator.
export async function saveRole(formData: FormData) {
  const { supabase, organization, membership } = await requireAppContext()
  if (membership.role !== 'admin') return fail('not_authorized')

  const roleId = text(formData, 'role_id')
  if (roleId && !isUuid(roleId)) return fail('invalid_input')
  const scope = text(formData, 'scope')
  if (!isScope(scope)) return fail('invalid_role_scope')
  const permissions = formData.getAll('permissions').map(String)
  if (!permissions.every(isPermission)) return fail('unknown_permission')
  const name = text(formData, 'name')
  const tier = text(formData, 'tier')
  // New role key: derived from the name (lowercase ascii, underscores).
  const key = roleId ? null : name.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').replace(/^([^a-z])/, 'p_$1').slice(0, 40)

  const { data, error } = await supabase.rpc('save_organization_role', {
    p_org: organization.id,
    p_role_id: roleId || null,
    p_key: key,
    p_name: name,
    p_tier: tier,
    p_scope: scope,
    p_permissions: permissions,
    p_is_active: text(formData, 'is_active') !== 'false',
  })
  if (error) return fail(classifyTeamError(error))
  revalidatePath('/app/configuracao/papeis')
  return back(`ok=role_saved&papel=${data}`)
}
