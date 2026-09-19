import 'server-only'
import { headers } from 'next/headers'

// Origin used to build the redirect of Auth e-mails (invitation, password recovery).
// 1. NEXT_PUBLIC_SITE_URL wins (REQUIRED in production: see docs/deployment/ENVIRONMENT-VARIABLES.md).
// 2. Otherwise the request's own Origin header is accepted ONLY when its host equals the host the request was addressed to (same-origin), so a forged
//    Origin can never point an e-mail link at another site. Anything else yields null and the caller falls back to the Supabase Site URL.
// Only http(s) origins are accepted, and callers append a FIXED path (never a caller-supplied one): there is no open redirect.
export async function siteOrigin(): Promise<string | null> {
  const parse = (v: string) => { try { const u = new URL(v); return u.protocol === 'https:' || u.protocol === 'http:' ? u : null } catch { return null } }
  const configured = process.env.NEXT_PUBLIC_SITE_URL
  if (configured) return parse(configured)?.origin ?? null
  const h = await headers()
  const origin = parse(h.get('origin') ?? '')
  const host = (h.get('x-forwarded-host') ?? h.get('host') ?? '').split(',')[0].trim().toLowerCase()
  return origin && host && origin.host.toLowerCase() === host ? origin.origin : null
}
