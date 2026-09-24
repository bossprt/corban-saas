// CPF check-digit validation (pure). CPF is PII: it is only ever handled in server actions and request bodies, never placed in a URL or a log line.
export function isValidCpf(cpf: string): boolean {
  if (!/^\d{11}$/.test(cpf) || /^(\d)\1{10}$/.test(cpf)) return false
  const digit = (length: number) => {
    let sum = 0
    for (let i = 0; i < length; i += 1) sum += Number(cpf[i]) * (length + 1 - i)
    const remainder = (sum * 10) % 11
    return remainder === 10 ? 0 : remainder
  }
  return digit(9) === Number(cpf[9]) && digit(10) === Number(cpf[10])
}

export function maskCpf(value: string | null | undefined): string {
  if (!value) return '—'
  const d = value.replace(/\D/g, '')
  return d.length === 11 ? `***.${d.slice(3, 6)}.${d.slice(6, 9)}-**` : '***.***.***-**'
}

// Full CPF for screens (owner decision: no masking). Never put it in a URL or a log line.
export function formatCpf(value: string | null | undefined): string {
  const d = String(value ?? '').replace(/\D/g, '')
  return d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : '—'
}

// Phones are stored as 55 + area code + number; shown as (68) 99900-0101.
export function formatPhone(value: string | null | undefined): string {
  const d = String(value ?? '').replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, '')
  if (d.length === 11) return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`
  if (d.length === 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`
  return value ? String(value) : '—'
}
