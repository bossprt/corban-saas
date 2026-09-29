'use server'

import { createClient } from '@/utils/supabase/server'
import { clearMustChangePassword } from '@/lib/team.server'

// Called right after the person saved their own password: the identity comes from Auth (never from the form), and only
// the first-entry requirement of that same person is cleared.
export async function passwordChosen(): Promise<boolean> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return false
  if (user.app_metadata?.must_change_password !== true) return true
  return clearMustChangePassword(user.id)
}
