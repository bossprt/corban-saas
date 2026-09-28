import { type NextRequest } from 'next/server'
import { updateSession } from './utils/supabase/middleware'

export async function proxy(request: NextRequest) {
  return await updateSession(request)
}

// Next 16 only runs the proxy next to the app directory (src/). The public API (key-authenticated) and the health probe
// skip it (so do the app manifest and icons, fetched before login); other API routes answer 401 themselves instead of being redirected to the login page.
export const config = {
  matcher: [
    '/((?!api/v1/|api/health|_next/static|_next/image|favicon.ico|manifest.webmanifest|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
