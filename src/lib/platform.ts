// Platform-level helpers (pure): organization identity checks and validation of the global reference catalog payload.
// Global reference data (banks, providers, agreements, products, modalities, document types) is shared by all tenants and can only be written
// by a platform administrator through the server route; tenant administrators build their own routes, tables and checklists on top of it.

export function digitsOnly(v: string): string { return v.replace(/\D/g, '') }

export function isValidCnpj(raw: string): boolean {
  const c = digitsOnly(raw)
  if (c.length !== 14 || /^(\d)\1{13}$/.test(c)) return false
  const dv = (len: number) => {
    const w = len === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    const sum = w.reduce((s, x, i) => s + x * Number(c[i]), 0)
    const r = sum % 11
    return r < 2 ? 0 : 11 - r
  }
  return dv(12) === Number(c[12]) && dv(13) === Number(c[13])
}

// "Smart Promotora", "SMART PROMOTORA LTDA", "Smart  Promotora  S.A." -> "smart promotora"
export function normalizeOrgName(name: string): string {
  return name.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ').replace(/\b(ltda|me|epp|eireli|s a|sa|ss|cia|companhia)\b/g, ' ').replace(/\s+/g, ' ').trim()
}
export const sameOrganizationName = (a: string, b: string) => { const x = normalizeOrgName(a); return x.length > 0 && x === normalizeOrgName(b) }

const CODE = /^[A-Za-z0-9_.-]{1,40}$/
const PROVIDER_TYPES = new Set(['bank_direct', 'master', 'promotora', 'other'])
const MAX_ITEMS = 100
export type ReferenceCatalog = {
  banks: { code: string; name: string }[]
  providers: { code: string; name: string; providerType: string }[]
  agreements: { bankCode: string; code: string; name: string }[]
  products: { code: string; name: string }[]
  modalities: { productCode: string; code: string; name: string }[]
  documentTypes: { code: string; name: string }[]
}
export type CatalogValidation = { ok: true; value: ReferenceCatalog } | { ok: false; error: string }

const str = (v: unknown, max: number) => (typeof v === 'string' && v.trim().length >= 1 && v.trim().length <= max ? v.trim() : null)
const code = (v: unknown) => (typeof v === 'string' && CODE.test(v) ? v : null)

export function validateReferenceCatalog(body: unknown): CatalogValidation {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'invalid_body' }
  const b = body as Record<string, unknown>
  const out: ReferenceCatalog = { banks: [], providers: [], agreements: [], products: [], modalities: [], documentTypes: [] }
  const list = (k: string): unknown[] | null => { const v = b[k]; if (v === undefined) return []; return Array.isArray(v) && v.length <= MAX_ITEMS ? v : null }
  const shapes: [keyof ReferenceCatalog, (o: Record<string, unknown>) => unknown | null][] = [
    ['banks', o => { const c = code(o.code), n = str(o.name, 120); return c && n ? { code: c, name: n } : null }],
    ['providers', o => { const c = code(o.code), n = str(o.name, 120); return c && n && typeof o.providerType === 'string' && PROVIDER_TYPES.has(o.providerType) ? { code: c, name: n, providerType: o.providerType } : null }],
    ['agreements', o => { const bc = code(o.bankCode), c = code(o.code), n = str(o.name, 120); return bc && c && n ? { bankCode: bc, code: c, name: n } : null }],
    ['products', o => { const c = code(o.code), n = str(o.name, 120); return c && n ? { code: c, name: n } : null }],
    ['modalities', o => { const pc = code(o.productCode), c = code(o.code), n = str(o.name, 120); return pc && c && n ? { productCode: pc, code: c, name: n } : null }],
    ['documentTypes', o => { const c = code(o.code), n = str(o.name, 120); return c && n ? { code: c, name: n } : null }],
  ]
  for (const key of Object.keys(b)) if (!shapes.some(([k]) => k === key)) return { ok: false, error: `unknown_field:${key}` }
  for (const [key, parse] of shapes) {
    const items = list(key)
    if (!items) return { ok: false, error: `invalid_list:${key}` }
    for (const it of items) {
      if (!it || typeof it !== 'object' || Array.isArray(it)) return { ok: false, error: `invalid_item:${key}` }
      const parsed = parse(it as Record<string, unknown>)
      if (!parsed) return { ok: false, error: `invalid_item:${key}` }
      ;(out[key] as unknown[]).push(parsed)
    }
  }
  const total = Object.values(out).reduce((s, l) => s + l.length, 0)
  if (total === 0) return { ok: false, error: 'empty_catalog' }
  return { ok: true, value: out }
}
