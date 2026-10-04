import { isValidCpf } from '../cpf'
import { parseMoneyInput } from '../money-input'

// Contract import layouts (owner request 02/10/2026): a bank's spreadsheet of contracts becomes proposals without typing
// them one by one. A layout fixes the bank and lists the column names it recognises. Every known column is read when
// present; a missing optional column never refuses the file (owner rule). A line is refused only for what makes it
// meaningless (no CPF, table, term or amount) or a malformed value in a column that is present. Unknown columns that
// look like money refuse the file, so an amount is never silently dropped.

export type ContractLayout = { key: string; label: string; bankName: string }
export const CONTRACT_LAYOUTS: ContractLayout[] = [{ key: 'nasp', label: 'NASP', bankName: 'NASP' }]
export const MAX_CONTRACT_LINES = 500

export type ContractField =
  | 'cpf' | 'name' | 'table' | 'term' | 'released' | 'requested' | 'installment' | 'ade' | 'type' | 'stage' | 'paidOn'
  | 'seller' | 'originBank' | 'originContract' | 'outstanding' | 'phone' | 'email' | 'note' | 'agreement' | 'category'

// Header aliases, compared after normalize() (lower case, no accents, no "*", single spaces).
const ALIASES: Record<ContractField, string[]> = {
  cpf: ['cpf', 'cpf do cliente', 'cpf cliente'],
  name: ['nome', 'nome do cliente', 'cliente', 'nome cliente'],
  table: ['tabela', 'nome da tabela', 'tabela comercial'],
  term: ['prazo', 'prazo (meses)', 'prazo meses', 'parcelas', 'qtd parcelas', 'quantidade de parcelas'],
  released: ['valor liberado', 'liberado', 'valor liquido', 'valor do cliente'],
  requested: ['valor solicitado', 'solicitado', 'valor bruto', 'valor do contrato', 'valor contrato', 'valor financiado'],
  installment: ['valor da parcela', 'parcela', 'valor parcela'],
  ade: ['n contrato/ade', 'no contrato/ade', 'nº contrato/ade', 'ade', 'contrato', 'n contrato', 'numero do contrato', 'numero contrato', 'n ade', 'proposta', 'n proposta'],
  type: ['tipo', 'tipo de contrato', 'operacao', 'tipo operacao', 'tipo de operacao'],
  stage: ['etapa', 'status', 'situacao'],
  paidOn: ['pago ao cliente em', 'data pagamento', 'data de pagamento', 'pago em', 'data do pagamento'],
  seller: ['vendedor', 'corretor', 'digitador', 'consultor'],
  originBank: ['banco de origem', 'banco origem'],
  originContract: ['contrato de origem', 'contrato origem'],
  outstanding: ['saldo devedor', 'saldo'],
  phone: ['telefone', 'celular', 'fone', 'whatsapp'],
  email: ['e-mail', 'email'],
  note: ['observacao', 'observacoes', 'obs'],
  agreement: ['convenio', 'orgao'],
  category: ['categoria', 'vinculo'],
}

export const normalize = (s: string) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[*º°]/g, ' ').toLowerCase().replace(/\s+/g, ' ').trim()

const ALIAS_INDEX = new Map<string, ContractField>()
for (const [field, names] of Object.entries(ALIASES) as [ContractField, string[]][]) for (const n of names) ALIAS_INDEX.set(normalize(n), field)

// Columns that look like money but are not recognised: refusing beats ignoring an amount.
const MONEY_HINT = /(valor|saldo|r\$|comiss|repasse|tarifa|iof|seguro|troco)/

export type HeaderIssue = { code: 'missing_column' | 'duplicate_column' | 'unknown_money_column'; column: string }
export type HeaderMap = { columns: Partial<Record<ContractField, number>>; ignored: string[]; issues: HeaderIssue[] }

export function mapContractHeader(header: string[]): HeaderMap {
  const columns: Partial<Record<ContractField, number>> = {}
  const ignored: string[] = []
  const issues: HeaderIssue[] = []
  header.forEach((raw, i) => {
    const h = normalize(raw)
    if (!h) return
    const field = ALIAS_INDEX.get(h)
    if (!field) {
      if (MONEY_HINT.test(h)) issues.push({ code: 'unknown_money_column', column: raw.trim() })
      else ignored.push(raw.trim())
      return
    }
    if (columns[field] !== undefined) issues.push({ code: 'duplicate_column', column: raw.trim() })
    else columns[field] = i
  })
  for (const f of ['cpf', 'table', 'term'] as const) if (columns[f] === undefined) issues.push({ code: 'missing_column', column: FIELD_LABEL[f] })
  if (columns.released === undefined && columns.requested === undefined) issues.push({ code: 'missing_column', column: 'Valor liberado ou Valor solicitado' })
  return { columns, ignored, issues }
}

export const FIELD_LABEL: Record<ContractField, string> = {
  cpf: 'CPF', name: 'Nome', table: 'Tabela', term: 'Prazo (meses)', released: 'Valor liberado', requested: 'Valor solicitado',
  installment: 'Valor da parcela', ade: 'Nº contrato/ADE', type: 'Tipo', stage: 'Etapa', paidOn: 'Pago ao cliente em',
  seller: 'Vendedor', originBank: 'Banco de origem', originContract: 'Contrato de origem', outstanding: 'Saldo devedor',
  phone: 'Telefone', email: 'E-mail', note: 'Observação', agreement: 'Convênio', category: 'Categoria',
}

// Contract types by what people write; the value is contract_types.tech_key.
const TYPE_KEYS: Record<string, string> = {
  novo: 'novo', 'contrato novo': 'novo', 'margem livre': 'novo', 'emprestimo novo': 'novo',
  refin: 'refinanciamento', refinanciamento: 'refinanciamento', 'refin normal': 'refinanciamento',
  compra: 'compra_de_divida', 'compra de divida': 'compra_de_divida', 'compra normal': 'compra_de_divida',
  portabilidade: 'portabilidade', port: 'portabilidade',
  'refin/portabilidade': 'refin_portabilidade', 'refin portabilidade': 'refin_portabilidade', 'refin de portabilidade': 'refin_portabilidade',
}
// Stages by code, name or common spelling; the value is the canonical state.
const STAGE_KEYS: Record<string, string> = {
  fila: 'digitization_queue', 'fila de digitacao': 'digitization_queue', 'aguardando digitacao': 'digitization_queue', fila_digitacao: 'digitization_queue',
  digitando: 'digitizing', 'em digitacao': 'digitizing',
  enviada: 'submitted', 'em analise': 'submitted', 'em analise no banco': 'submitted', digitada: 'submitted',
  pendencia: 'pending_external', pendente: 'pending_external',
  aprovada: 'approved', aprovado: 'approved',
  paga: 'paid', pago: 'paid',
  recusada: 'rejected', recusado: 'rejected', reprovada: 'rejected',
  cancelada: 'cancelled', cancelado: 'cancelled',
}

export type LineIssue =
  | 'cpf_required' | 'cpf_invalid' | 'table_required' | 'term_required' | 'term_invalid' | 'amount_required' | 'amount_invalid'
  | 'type_unknown' | 'stage_unknown' | 'paid_on_invalid' | 'paid_on_required'

export type ContractLine = {
  line: number
  cpf: string; name: string; table: string; term: number | null
  released: string | null; requested: string | null; installment: string | null; outstanding: string | null
  ade: string; typeKey: string | null; stage: string | null; paidOn: string | null
  seller: string; originBank: string; originContract: string; phone: string; email: string; note: string
  issues: LineIssue[]
}

const isoDate = (raw: string): string | null | 'invalid' => {
  const s = raw.trim()
  if (!s) return null
  let y: number, m: number, d: number
  const br = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s)
  const iso = /^(\d{4})-(\d{2})-(\d{2})(T.*)?$/.exec(s)
  if (br) [d, m, y] = [Number(br[1]), Number(br[2]), Number(br[3])]
  else if (iso) [y, m, d] = [Number(iso[1]), Number(iso[2]), Number(iso[3])]
  else return 'invalid'
  const dt = new Date(Date.UTC(y, m - 1, d))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return 'invalid'
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

// One spreadsheet row into a contract line. `today` (yyyy-mm-dd, Brasília) bounds "Pago ao cliente em".
export function parseContractLine(row: string[], columns: HeaderMap['columns'], line: number, today: string): ContractLine {
  const get = (f: ContractField) => (columns[f] === undefined ? '' : String(row[columns[f]!] ?? '').trim())
  const issues: LineIssue[] = []
  const money = (f: ContractField) => {
    const v = parseMoneyInput(get(f))
    if (v === 'invalid') { issues.push('amount_invalid'); return null }
    return v
  }
  // Excel drops leading zeros of a CPF typed as a number: 1234567890 is 01234567890.
  const cpfDigits = get('cpf').replace(/\D/g, '')
  const cpf = cpfDigits && cpfDigits.length < 11 ? cpfDigits.padStart(11, '0') : cpfDigits
  if (!cpf) issues.push('cpf_required')
  else if (!isValidCpf(cpf)) issues.push('cpf_invalid')
  const table = get('table')
  if (!table) issues.push('table_required')
  const termText = get('term').replace(/\s*(meses|x)$/i, '')
  let term: number | null = null
  if (!termText) issues.push('term_required')
  else if (!/^\d{1,3}$/.test(termText) || Number(termText) < 1 || Number(termText) > 420) issues.push('term_invalid')
  else term = Number(termText)
  const released = money('released')
  const requested = money('requested')
  const installment = money('installment')
  const outstanding = money('outstanding')
  if (!released && !requested && !issues.includes('amount_invalid')) issues.push('amount_required')
  const typeText = normalize(get('type'))
  const typeKey = typeText ? TYPE_KEYS[typeText] ?? null : null
  if (typeText && !typeKey) issues.push('type_unknown')
  const stageText = normalize(get('stage'))
  const stage = stageText ? STAGE_KEYS[stageText] ?? null : null
  if (stageText && !stage) issues.push('stage_unknown')
  const paid = isoDate(get('paidOn'))
  const paidOn = paid === 'invalid' ? null : paid
  if (paid === 'invalid' || (paidOn && paidOn > today)) issues.push('paid_on_invalid')
  if (stage === 'paid' && !paidOn && paid !== 'invalid') issues.push('paid_on_required')
  const ade = get('ade')
  return {
    line, cpf, name: get('name'), table, term, released, requested, installment, outstanding,
    ade, typeKey, stage, paidOn, seller: get('seller'), originBank: get('originBank'), originContract: get('originContract'),
    phone: get('phone'), email: get('email'), note: get('note').slice(0, 500), issues,
  }
}

// The whole sheet: header on the first non-empty row, blank lines skipped.
export function parseContractSheet(rows: string[][], today: string) {
  const [header = [], ...body] = rows
  const map = mapContractHeader(header)
  if (map.issues.length) return { map, lines: [] as ContractLine[], tooMany: false }
  const tooMany = body.length > MAX_CONTRACT_LINES
  const lines = body.slice(0, MAX_CONTRACT_LINES).map((r, i) => parseContractLine(r, map.columns, i + 2, today))
  return { map, lines, tooMany }
}

// Match the sheet's "Tabela" against the bank's table names ("NASP - Gov. Acre - Temporário (4 a 7 meses)" for
// "Temporário (4 a 7 meses)"). Ambiguous matches are refused.
export function matchTable<T extends { name: string }>(sheetName: string, tables: T[]): T | 'none' | 'ambiguous' {
  const want = normalize(sheetName)
  // Tiers, first hit wins: the full name; the last " - " part of the name ("Temporário (4 a 7 meses)" is the Governo do
  // Acre table, not "Prefeitura Temporário (4 a 7 meses)"); any name ending with it.
  const tiers: ((n: string) => boolean)[] = [
    n => n === want,
    n => n.split(' - ').at(-1) === want,
    n => n.endsWith(` ${want}`) || n.endsWith(`-${want}`),
  ]
  for (const hit of tiers) {
    const found = tables.filter(t => hit(normalize(t.name)))
    if (found.length === 1) return found[0]
    if (found.length > 1) return 'ambiguous'
  }
  return 'none'
}
