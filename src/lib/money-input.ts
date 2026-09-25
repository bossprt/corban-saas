// Parses a money value typed by an operator ("9.500,00", "9500,5", "9500.00", "R$ 1.234") into an exact decimal
// string with two places ("9500.00"). Never goes through a JavaScript number, so no floating point is involved.
// Returns null for empty input and 'invalid' for anything that is not a non-negative amount.
export function parseMoneyInput(raw: unknown): string | null | 'invalid' {
  const s = String(raw ?? '').replace(/R\$|\s/g, '')
  if (s === '') return null
  let integer: string
  let fraction = ''
  if (/^\d{1,3}(\.\d{3})*(,\d{1,2})?$/.test(s) || /^\d+(,\d{1,2})?$/.test(s)) {
    ;[integer, fraction = ''] = s.replace(/\./g, '').split(',')
  } else if (/^\d+(\.\d{1,2})?$/.test(s)) {
    ;[integer, fraction = ''] = s.split('.')
  } else {
    return 'invalid'
  }
  integer = integer.replace(/^0+(?=\d)/, '')
  if (integer.length > 12) return 'invalid'
  return `${integer}.${fraction.padEnd(2, '0')}`
}
