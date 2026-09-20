import { createHash, timingSafeEqual } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'
import { NextResponse } from 'next/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const TARGET_USER_ID = 'e9af738c-cfea-4994-b28c-23d774ad19d6'
const TARGET_EMAIL = 'josicleuton.braga@gmail.com'
const TOKEN_SHA256 = '546ee9d22f82195d60cf3e463485e735fa5d70ab116c35162e263ee55009abab'
const MIN_LENGTH = 12
const MAX_LENGTH = 128

function response(body: Record<string, unknown>, status: number) {
  return NextResponse.json(body, {
    status,
    headers: {
      'cache-control': 'no-store, max-age=0',
      pragma: 'no-cache',
    },
  })
}

function validToken(value: unknown) {
  if (typeof value !== 'string' || value.length < 32 || value.length > 256) return false
  const actual = createHash('sha256').update(value).digest()
  const expected = Buffer.from(TOKEN_SHA256, 'hex')
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

function expectedOrigin() {
  try {
    return new URL(process.env.NEXT_PUBLIC_SITE_URL ?? '').origin
  } catch {
    return null
  }
}

export async function POST(request: Request) {
  const origin = request.headers.get('origin')
  const allowedOrigin = expectedOrigin()
  if (!allowedOrigin || origin !== allowedOrigin) return response({ error: 'Origem não autorizada.' }, 403)

  let body: { token?: unknown; password?: unknown }
  try {
    body = await request.json()
  } catch {
    return response({ error: 'Requisição inválida.' }, 400)
  }

  if (!validToken(body.token)) return response({ error: 'Acesso inválido ou expirado.' }, 401)
  if (typeof body.password !== 'string' || body.password.length < MIN_LENGTH || body.password.length > MAX_LENGTH) {
    return response({ error: `A senha deve ter entre ${MIN_LENGTH} e ${MAX_LENGTH} caracteres.` }, 400)
  }

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim().replace(/\/$/, '')
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim()
  if (!supabaseUrl || !serviceRoleKey) return response({ error: 'Serviço indisponível.' }, 503)

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: existing, error: readError } = await admin.auth.admin.getUserById(TARGET_USER_ID)
  if (readError || !existing.user || existing.user.email?.toLowerCase() !== TARGET_EMAIL) {
    return response({ error: 'Conta administrativa não disponível.' }, 409)
  }

  if (existing.user.user_metadata?.bootstrap_password_set_at) {
    return response({ error: 'Este acesso já foi utilizado.' }, 410)
  }

  const userMetadata = {
    ...(existing.user.user_metadata ?? {}),
    bootstrap_password_set_at: new Date().toISOString(),
  }

  const { data: updated, error: updateError } = await admin.auth.admin.updateUserById(TARGET_USER_ID, {
    password: body.password,
    user_metadata: userMetadata,
  })

  if (updateError || !updated.user || updated.user.email?.toLowerCase() !== TARGET_EMAIL) {
    return response({ error: 'Não foi possível definir a senha.' }, 500)
  }

  return response({ ok: true }, 200)
}
