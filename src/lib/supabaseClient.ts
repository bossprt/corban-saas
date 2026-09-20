import { createBrowserClient } from '@supabase/ssr'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim().replace(/\/+$/, '')
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim()

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Supabase public environment variables are required')
}

export const supabase = createBrowserClient(supabaseUrl, supabaseAnonKey)
