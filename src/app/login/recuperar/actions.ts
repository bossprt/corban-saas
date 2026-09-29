'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@supabase/supabase-js'
import { normalizeEmail } from '@/lib/team'
import { siteOrigin } from '@/lib/site-origin'

// Password recovery through Supabase Auth (no credential handling of our own). The public answer is IDENTICAL whether the e-mail has an
// account or not, and Auth errors are swallowed: the page never reveals which addresses exist.
export async function requestPasswordReset(formData: FormData) {
  const email = normalizeEmail(formData.get('email'))
  if (!email) redirect('/login/recuperar?erro=email')
  try {
    const origin = await siteOrigin()
    // Implicit flow on purpose: the link then carries its own session and works on any device (e.g. asked on the computer,
    // opened on the phone). The PKCE flow would only work in the browser that asked, because the verifier lives in its cookie.
    const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!.trim(), process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim(),
      { auth: { flowType: 'implicit', persistSession: false, autoRefreshToken: false } })
    await supabase.auth.resetPasswordForEmail(email, origin ? { redirectTo: `${origin}/auth/definir-senha` } : undefined)
  } catch {
    // intentionally silent: same response for unknown address, provider error or rate limit
  }
  redirect('/login/recuperar?enviado=1')
}
