import { createHash, timingSafeEqual } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'
import { NextResponse } from 'next/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const TARGET_USER_ID = '9917cdc3-bca0-4249-91a4-20fec75ef26a'
const TARGET_EMAIL = 'josicleuton@smartpromotora.com.br'
const TOKEN_SHA256 = 'da9b24076992dd17ae14cc90fbc89432c77eb3affbe9c4d0aeb72e5cf60f189d'

function json(body: Record<string, unknown>, status: number) {
  return NextResponse.json(body, { status, headers: { 'cache-control': 'no-store' } })
}

function tokenOk(v: unknown) {
  if (typeof v !== 'string') return false
  const a = createHash('sha256').update(v).digest()
  const b = Buffer.from(TOKEN_SHA256, 'hex')
  return a.length === b.length && timingSafeEqual(a, b)
}

export async function POST(request: Request) {
  const expectedOrigin = new URL(process.env.NEXT_PUBLIC_SITE_URL ?? 'https://corban-saas.vercel.app').origin
  if (request.headers.get('origin') !== expectedOrigin) return json({ error: 'Origem não autorizada.' }, 403)

  const body = await request.json().catch(() => null) as { token?: unknown; password?: unknown } | null
  if (!body || !tokenOk(body.token)) return json({ error: 'Acesso inválido ou expirado.' }, 401)
  if (typeof body.password !== 'string' || body.password.length < 12 || body.password.length > 128) {
    return json({ error: 'A senha deve ter entre 12 e 128 caracteres.' }, 400)
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim().replace(/\/$/, '')
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim()
  if (!url || !key) return json({ error: 'Serviço indisponível.' }, 503)

  const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: current, error: readError } = await admin.auth.admin.getUserById(TARGET_USER_ID)
  if (readError || !current.user || current.user.email?.toLowerCase() !== TARGET_EMAIL) {
    return json({ error: 'Conta administrativa não disponível.' }, 409)
  }
  if (current.user.user_metadata?.bootstrap_password_set_at_smart) {
    return json({ error: 'Este acesso já foi utilizado.' }, 410)
  }

  const { data, error } = await admin.auth.admin.updateUserById(TARGET_USER_ID, {
    password: body.password,
    user_metadata: {
      ...(current.user.user_metadata ?? {}),
      bootstrap_password_set_at_smart: new Date().toISOString(),
    },
  })

  if (error || !data.user) return json({ error: 'Não foi possível definir a senha.' }, 500)
  return json({ ok: true }, 200)
}
