import { NextResponse, type NextRequest } from 'next/server'
import { createClient } from '@/utils/supabase/server'

// Landing point for e-mail links that carry a token_hash (Supabase e-mail templates using {{ .TokenHash }}).
// The token is verified by Supabase Auth and never logged, echoed or stored by us; the destination is FIXED (no open redirect).
const ALLOWED_TYPES = new Set(['invite', 'recovery', 'magiclink', 'email'])

export async function GET(request: NextRequest) {
  const tokenHash = request.nextUrl.searchParams.get('token_hash')
  const type = request.nextUrl.searchParams.get('type') ?? ''
  const fail = () => NextResponse.redirect(new URL('/login?erro=link', request.url))
  if (!tokenHash || !ALLOWED_TYPES.has(type)) return fail()
  const supabase = await createClient()
  const { error } = await supabase.auth.verifyOtp({ type: type as 'invite' | 'recovery' | 'magiclink' | 'email', token_hash: tokenHash })
  if (error) return fail()
  return NextResponse.redirect(new URL('/auth/definir-senha', request.url))
}
