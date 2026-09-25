import 'server-only'
import { createClient } from '@supabase/supabase-js'

export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim().replace(/\/+$/, '')
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim()
  if (!url || !serviceRole) throw new Error('Server-side Supabase admin environment is not configured')

  return createClient(url, serviceRole, {
    auth: { autoRefreshToken: false, persistSession: false }
  })
}
