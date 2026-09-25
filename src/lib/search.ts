// Minimal, safe search term for name/phone filters. PostgREST `.or()` filters are a mini-language: commas, parentheses, wildcards and backslashes in
// user input would change the filter's meaning, so they are removed. The term goes in the query string, so it is NEVER used for CPF or other PII.
export function searchTerm(raw: string | string[] | undefined | null): string | null {
  const v = Array.isArray(raw) ? raw[0] : raw
  const t = String(v ?? '').replace(/[,()%*_\\"'`;:]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60)
  return t.length >= 2 ? t : null
}
// Phone numbers are matched by digits only.
export const digitsOnly = (t: string) => t.replace(/\D/g, '')
