import 'server-only'
import { headers } from 'next/headers'

// Origin used to build the redirect of Auth e-mails (invitation, password recovery). NEXT_PUBLIC_SITE_URL wins; otherwise the request's own
// Origin header. Only http(s) origins are accepted, and the caller appends a FIXED path, so a forged header can at worst point the link at the
// attacker's own origin for a request THEY made (Supabase additionally enforces its Redirect URLs allow-list).
export async function siteOrigin(): Promise<string | null> {
  const candidate = process.env.NEXT_PUBLIC_SITE_URL || (await headers()).get('origin') || ''
  try {
    const u = new URL(candidate)
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.origin : null
  } catch {
    return null
  }
}
