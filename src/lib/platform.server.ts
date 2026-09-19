import 'server-only'
import { createClient } from '@/utils/supabase/server'
import { createAdminClient } from '@/lib/supabaseAdmin'

// Platform administrator gate for the /api/admin/* routes: a real session AND an active row in platform_administrators (read with the service role,
// because that table is closed to every tenant role).
export async function requirePlatformAdmin(): Promise<{ ok: true; userId: string } | { ok: false; status: 401 | 403 }> {
  const caller = await createClient()
  const { data: { user } } = await caller.auth.getUser()
  if (!user) return { ok: false, status: 401 }
  const { data, error } = await createAdminClient().from('platform_administrators').select('user_id').eq('user_id', user.id).eq('status', 'active').maybeSingle()
  if (error || !data) return { ok: false, status: 403 }
  return { ok: true, userId: user.id }
}
