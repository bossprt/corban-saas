// "6", "6,5", "12.25" -> "6", "6.5", "12.25"; empty -> null (inherit from a broader rule);
// anything else, or outside 0..100, -> 'invalid'. Kept as a decimal string: percentages never become floats.
export function parsePercentInput(raw: unknown): string | null | 'invalid' {
  const s = String(raw ?? '').trim().replace(',', '.')
  if (s === '') return null
  if (!/^\d{1,3}(\.\d{1,4})?$/.test(s)) return 'invalid'
  const [i, f = ''] = s.split('.')
  const int = Number.parseInt(i, 10)
  if (int > 100 || (int === 100 && /[1-9]/.test(f))) return 'invalid'
  return f ? `${int}.${f}` : String(int)
}
