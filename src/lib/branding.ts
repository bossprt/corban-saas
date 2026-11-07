// Company look (owner, 07/11/2026): primary color, accent color and logo per company. Pure helpers.
import { sniffDocumentMime } from './documents'

export const DEFAULT_BRAND = '#0b5fa8'
export const DEFAULT_ACCENT = '#f57c00'
export const MAX_LOGO_BYTES = 1024 * 1024
export const LOGO_BUCKET = 'org-branding'

// "#0B5FA8" or "0b5fa8" -> "#0b5fa8"; anything else -> null.
export function normalizeHex(v: unknown): string | null {
  const s = String(v ?? '').trim().toLowerCase()
  const m = /^#?([0-9a-f]{6})$/.exec(s)
  return m ? `#${m[1]}` : null
}

// The CSS the shell injects. Only colors that pass normalizeHex reach the page, so stored text can never inject CSS.
export function brandCss(brand: unknown, accent: unknown): string {
  const b = normalizeHex(brand), a = normalizeHex(accent)
  if (!b && !a) return ''
  return `:root{${b ? `--brand:${b};` : ''}${a ? `--accent:${a};` : ''}}`
}

export type LogoCheck = { ok: true; mime: 'image/png' | 'image/jpeg' | 'image/webp'; ext: 'png' | 'jpg' | 'webp' } | { ok: false; code: 'erro:doc_vazio' | 'erro:aparencia_logo_grande' | 'erro:aparencia_logo_formato' }

// Raster images only, decided from the file's own bytes (SVG, PDF and renamed files are refused), at most 1 MB.
export function checkLogo(size: number, declaredMime: string, bytes: Uint8Array): LogoCheck {
  if (size === 0 || bytes.length === 0) return { ok: false, code: 'erro:doc_vazio' }
  if (size > MAX_LOGO_BYTES || bytes.length > MAX_LOGO_BYTES) return { ok: false, code: 'erro:aparencia_logo_grande' }
  const real = sniffDocumentMime(bytes)
  if (real !== declaredMime) return { ok: false, code: 'erro:aparencia_logo_formato' }
  if (real === 'image/png') return { ok: true, mime: real, ext: 'png' }
  if (real === 'image/jpeg') return { ok: true, mime: real, ext: 'jpg' }
  if (real === 'image/webp') return { ok: true, mime: real, ext: 'webp' }
  return { ok: false, code: 'erro:aparencia_logo_formato' }
}

// Public URL of a stored logo; null when the path is not one the database would accept for this company.
export function logoUrl(supabaseUrl: string, organizationId: string, path: string | null | undefined): string | null {
  if (!path || !new RegExp(`^${organizationId}/[0-9a-f-]{36}\\.(png|jpg|webp)$`).test(path)) return null
  return `${supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/public/${LOGO_BUCKET}/${path}`
}
