// Upload safety helpers (pure). The browser-declared MIME type is only a hint; the accepted type is decided from the file's own first bytes.
// 4 MB: Vercel serverless functions reject request bodies above 4.5 MB, and an upload goes through a server action. Larger files need a direct-to-Storage
// signed upload (P1, see docs/DEPLOY.md); until then the limit is stated honestly instead of failing with an opaque platform error.
export const MAX_DOCUMENT_BYTES = 4 * 1024 * 1024
export const ALLOWED_DOCUMENT_MIME = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'] as const
export type DocumentMime = (typeof ALLOWED_DOCUMENT_MIME)[number]

const startsWith = (b: Uint8Array, sig: number[], at = 0) => sig.every((v, i) => b[at + i] === v)

// Returns the real type when the bytes are a PDF, JPEG, PNG or WebP; null for everything else (SVG/HTML/scripts/executables/renamed files).
export function sniffDocumentMime(bytes: Uint8Array): DocumentMime | null {
  if (bytes.length < 12) return null
  if (startsWith(bytes, [0x25, 0x50, 0x44, 0x46, 0x2d])) return 'application/pdf'          // %PDF-
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return 'image/jpeg'
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png'
  if (startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp' // RIFF....WEBP
  return null
}

// Storage object name: no path separators, no traversal, no control or non-ASCII characters, bounded length.
export function safeFileName(name: string): string {
  const cleaned = name.normalize('NFKD').replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/-+/g, '-').replace(/^[.-]+/, '').replace(/\.{2,}/g, '.')
  return cleaned.slice(-120) || 'document'
}

export type UploadCheck = { ok: true; mime: DocumentMime } | { ok: false; code: 'erro:doc_vazio' | 'erro:doc_grande' | 'erro:doc_formato' }
export function checkUpload(size: number, declaredMime: string, bytes: Uint8Array): UploadCheck {
  if (size === 0 || bytes.length === 0) return { ok: false, code: 'erro:doc_vazio' }
  if (size > MAX_DOCUMENT_BYTES || bytes.length > MAX_DOCUMENT_BYTES) return { ok: false, code: 'erro:doc_grande' }
  const real = sniffDocumentMime(bytes)
  // both must agree: an allowed declared type with different real content (e.g. HTML renamed .pdf) is refused
  if (!real || !(ALLOWED_DOCUMENT_MIME as readonly string[]).includes(declaredMime) || real !== declaredMime) return { ok: false, code: 'erro:doc_formato' }
  return { ok: true, mime: real }
}
