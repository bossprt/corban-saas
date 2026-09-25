import { NextResponse } from 'next/server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { validateReferenceCatalog } from '@/lib/platform'

// Global reference catalog (banks, providers, agreements, products, modalities, document types). Shared by every tenant, read-only for tenant roles,
// written ONLY here by a platform administrator. Idempotent: rows are upserted by code; nothing is ever deleted. The route invents no data: the caller
// supplies every code and name.
export const dynamic = 'force-dynamic'

const denied = (status: 401 | 403) => NextResponse.json({ error: status === 401 ? 'unauthorized' : 'platform_admin_required' }, { status })

export async function GET() {
  const gate = await requirePlatformAdmin()
  if (!gate.ok) return denied(gate.status)
  const admin = createAdminClient()
  const count = async (t: string) => (await admin.from(t).select('*', { count: 'exact', head: true })).count ?? 0
  const [banks, providers, agreements, products, modalities, documentTypes] = await Promise.all(['banks', 'providers', 'agreements', 'products', 'modalities', 'document_types'].map(count))
  return NextResponse.json({ banks, providers, agreements, products, modalities, documentTypes })
}

export async function POST(request: Request) {
  const gate = await requirePlatformAdmin()
  if (!gate.ok) return denied(gate.status)
  let body: unknown
  try { body = await request.json() } catch { return NextResponse.json({ error: 'invalid_json' }, { status: 400 }) }
  const v = validateReferenceCatalog(body)
  if (!v.ok) return NextResponse.json({ error: v.error }, { status: 400 })
  const c = v.value
  const admin = createAdminClient()
  const fail = (step: string) => NextResponse.json({ error: 'catalog_upsert_failed', step }, { status: 500 })

  if (c.banks.length && (await admin.from('banks').upsert(c.banks, { onConflict: 'code' })).error) return fail('banks')
  if (c.providers.length && (await admin.from('providers').upsert(c.providers.map(p => ({ code: p.code, name: p.name, provider_type: p.providerType })), { onConflict: 'code' })).error) return fail('providers')
  if (c.products.length && (await admin.from('products').upsert(c.products, { onConflict: 'code' })).error) return fail('products')
  if (c.documentTypes.length && (await admin.from('document_types').upsert(c.documentTypes, { onConflict: 'code' })).error) return fail('document_types')
  if (c.agreements.length) {
    const { data: banks } = await admin.from('banks').select('id,code').in('code', [...new Set(c.agreements.map(a => a.bankCode))])
    const byCode = new Map((banks ?? []).map(b => [b.code, b.id]))
    if (c.agreements.some(a => !byCode.has(a.bankCode))) return NextResponse.json({ error: 'unknown_bank_code' }, { status: 400 })
    if ((await admin.from('agreements').upsert(c.agreements.map(a => ({ bank_id: byCode.get(a.bankCode), code: a.code, name: a.name })), { onConflict: 'bank_id,code' })).error) return fail('agreements')
  }
  if (c.modalities.length) {
    const { data: products } = await admin.from('products').select('id,code').in('code', [...new Set(c.modalities.map(m => m.productCode))])
    const byCode = new Map((products ?? []).map(p => [p.code, p.id]))
    if (c.modalities.some(m => !byCode.has(m.productCode))) return NextResponse.json({ error: 'unknown_product_code' }, { status: 400 })
    if ((await admin.from('modalities').upsert(c.modalities.map(m => ({ product_id: byCode.get(m.productCode), code: m.code, name: m.name })), { onConflict: 'product_id,code' })).error) return fail('modalities')
  }
  const counts = { banks: c.banks.length, providers: c.providers.length, agreements: c.agreements.length, products: c.products.length, modalities: c.modalities.length, documentTypes: c.documentTypes.length }
  await admin.from('platform_admin_audit_events').insert({ actor_user_id: gate.userId, action: 'reference_catalog.upsert', metadata: counts })
  return NextResponse.json({ ok: true, upserted: counts }, { status: 201 })
}
