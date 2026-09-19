// Fail-closed access to the public Supabase settings. A missing value must stop the request with a clear, secret-free message instead of letting
// the app run against `undefined` (cryptic 500s, or a client silently talking to nothing).
export function publicSupabaseEnv(): { url: string; anonKey: string } {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!url || !anonKey) throw new Error('Configuração ausente: NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY são obrigatórias. Veja docs/deployment/ENVIRONMENT-VARIABLES.md.')
  return { url, anonKey }
}
