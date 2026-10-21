// A money amount in words, for printed statements ("R$ 289,20" -> "duzentos e oitenta e nove reais e vinte centavos").
// Works on the decimal text ("289.20"), never on a float.

const UNITS = ['', 'um', 'dois', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove', 'dez', 'onze', 'doze', 'treze',
  'quatorze', 'quinze', 'dezesseis', 'dezessete', 'dezoito', 'dezenove']
const TENS = ['', '', 'vinte', 'trinta', 'quarenta', 'cinquenta', 'sessenta', 'setenta', 'oitenta', 'noventa']
const HUNDREDS = ['', 'cento', 'duzentos', 'trezentos', 'quatrocentos', 'quinhentos', 'seiscentos', 'setecentos', 'oitocentos', 'novecentos']

function upTo999(n: number): string {
  if (n === 0) return ''
  if (n === 100) return 'cem'
  const parts: string[] = []
  const h = Math.floor(n / 100), rest = n % 100
  if (h) parts.push(HUNDREDS[h])
  if (rest < 20) { if (rest) parts.push(UNITS[rest]) }
  else {
    const t = Math.floor(rest / 10), u = rest % 10
    parts.push(u ? `${TENS[t]} e ${UNITS[u]}` : TENS[t])
  }
  return parts.join(' e ')
}

function integerWords(n: number): string {
  if (n === 0) return 'zero'
  const groups: [number, string, string][] = [[1_000_000_000, 'bilhão', 'bilhões'], [1_000_000, 'milhão', 'milhões'], [1000, 'mil', 'mil'], [1, '', '']]
  const parts: string[] = []
  let rest = n
  for (const [size, one, many] of groups) {
    const g = Math.floor(rest / size)
    rest %= size
    if (!g) continue
    if (size === 1000) parts.push(g === 1 ? 'mil' : `${upTo999(g)} mil`)
    else if (size === 1) parts.push(upTo999(g))
    else parts.push(`${upTo999(g)} ${g === 1 ? one : many}`)
  }
  // "mil e cem", "dois mil e trinta": the last group joins with "e" when it is under 100 or a round hundred.
  if (parts.length > 1) {
    const last = n % 1000
    if (last && (last < 100 || last % 100 === 0)) return `${parts.slice(0, -1).join(', ')} e ${parts.at(-1)}`
  }
  return parts.join(', ')
}

export function moneyInWords(decimal: string | number): string {
  const m = /^(-?)(\d+)(?:[.,](\d{1,2}))?$/.exec(String(decimal).trim())
  if (!m) return ''
  const reais = Number(m[2]), centavos = Number((m[3] ?? '0').padEnd(2, '0'))
  const r = reais ? `${integerWords(reais)}${reais % 1_000_000 === 0 && reais >= 1_000_000 ? ' de' : ''} ${reais === 1 ? 'real' : 'reais'}` : ''
  const c = centavos ? `${integerWords(centavos)} ${centavos === 1 ? 'centavo' : 'centavos'}` : ''
  const text = r && c ? `${r} e ${c}` : r || c || 'zero real'
  return m[1] ? `menos ${text}` : text
}
