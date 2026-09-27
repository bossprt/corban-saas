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

