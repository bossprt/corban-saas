import { test } from 'node:test'
import assert from 'node:assert/strict'
import { brandCss, checkLogo, logoUrl, normalizeHex } from '../../src/lib/branding'

const ORG = '00000000-0000-4000-8000-0000000ab001'
const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0, 0])
const svg = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')

test('branding: colors are normalized and anything else refused', () => {
  assert.equal(normalizeHex('#0B5FA8'), '#0b5fa8')
  assert.equal(normalizeHex('f57c00'), '#f57c00')
  for (const bad of ['blue', '#fff', '#0b5fa8;}body{', '', null, undefined, 'url(x)']) assert.equal(normalizeHex(bad), null)
})

test('branding: injected CSS carries only valid colors', () => {
  assert.equal(brandCss('#0B5FA8', '#F57C00'), ':root{--brand:#0b5fa8;--accent:#f57c00;}')
  assert.equal(brandCss('red;}*{display:none', null), '')
  assert.equal(brandCss(null, '#f57c00'), ':root{--accent:#f57c00;}')
})

test('branding: logo must be a real PNG/JPEG/WebP up to 1 MB', () => {
  assert.deepEqual(checkLogo(png.length, 'image/png', png), { ok: true, mime: 'image/png', ext: 'png' })
  assert.equal(checkLogo(svg.length, 'image/svg+xml', svg).ok, false)
  assert.equal(checkLogo(png.length, 'image/jpeg', png).ok, false)
  assert.deepEqual(checkLogo(2 * 1024 * 1024, 'image/png', png), { ok: false, code: 'erro:aparencia_logo_grande' })
  assert.deepEqual(checkLogo(0, 'image/png', new Uint8Array()), { ok: false, code: 'erro:doc_vazio' })
})

test('branding: logo URL only for a path of the company folder', () => {
  const ok = `${ORG}/11111111-1111-4111-8111-111111111111.png`
  assert.equal(logoUrl('https://x.supabase.co/', ORG, ok), `https://x.supabase.co/storage/v1/object/public/org-branding/${ok}`)
  assert.equal(logoUrl('https://x.supabase.co', ORG, `00000000-0000-4000-8000-0000000ab002/11111111-1111-4111-8111-111111111111.png`), null)
  assert.equal(logoUrl('https://x.supabase.co', ORG, null), null)
})
