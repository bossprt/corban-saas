import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { publicSupabaseEnv } from '@/lib/env'

export async function createClient() {
  const cookieStore = await cookies()
  const { url, anonKey } = publicSupabaseEnv()

  return createServerClient(
    url,
    anonKey,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            )
          } catch {
            // O setAll foi chamado de um Server Component. Pode ser ignorado se houver middleware.
          }
        },
      },
    }
  )
}
