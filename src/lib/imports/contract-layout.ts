import { isValidCpf } from '../cpf'
import { normalizeCep } from '../cep'
import { parseMoneyInput } from '../money-input'

// Contract import layouts (owner request 02/10/2026): a bank's spreadsheet of contracts becomes proposals without typing
// them one by one. A layout fixes the bank and may teach its own column names (the NASP export, for example). Every known
// column is read when present; a missing optional column never refuses the file (owner rule). A line is refused only for
// what makes the contract meaningless (no CPF, table, term or amount) or a malformed value in a contract column. Client
// data (birth, RG, address, bank account, registration) only enriches the client record: a bad value there is skipped
// with a warning, never refusing the contract. Unknown columns that look like money refuse the file, so an amount is
// never silently dropped; a layout lists the money columns it ignores on purpose.

export type ContractField =
  | 'cpf' | 'name' | 'table' | 'term' | 'released' | 'requested' | 'installment' | 'ade' | 'type' | 'stage' | 'paidOn'
  | 'seller' | 'originBank' | 'originContract' | 'outstanding' | 'phone' | 'email' | 'note' | 'agreement' | 'category'
  | 'birthDate' | 'gender' | 'maritalStatus' | 'birthplace' | 'motherName' | 'fatherName' | 'rgNumber' | 'rgIssuer' | 'rgState'
  | 'rgIssuedOn' | 'whatsapp' | 'zip' | 'street' | 'number' | 'complement' | 'district' | 'city' | 'state'
  | 'bankCode' | 'bankName' | 'branch' | 'account' | 'accountDigit' | 'accountType' | 'registration' | 'agency'

export type ContractLayout = {
  key: string; label: string; bankName: string
  // The layout's own column names (after normalize): a field, or 'ignore' for a column it knows and does not use.
  columns?: Record<string, ContractField | 'ignore'>
  // The bank's own product names (after normalize) for the company's table names, when the export shortens them.
  tables?: Record<string, string>
}

// The NASP contract export ("contratos pagos"), as the bank sends it (owner request 03/10/2026).
const NASP_COLUMNS: Record<string, ContractField | 'ignore'> = {
  // "Tipo" (emprestimo) stays a type column after "Operação" (novo, refin): the first non-empty one wins, and the
  // Corban template, which has only "Tipo", keeps working with this layout.
  operacao: 'type', fase: 'stage', situacao: 'ignore', 'n proposta': 'ignore', origem: 'ignore',
  'data do pagamento': 'ignore', 'forma de pagamento': 'ignore', 'data da liberacao': 'paidOn', 'data do contrato': 'ignore',
  'data 1a parcela': 'ignore', 'data ultima parcela': 'ignore', 'qtd parcelas': 'term',
  'valor liquido pago': 'released', 'valor bruto liberado': 'requested', 'valor final': 'ignore',
  'saldo por dentro (refin)': 'outstanding', 'quitacao externa (compra divida)': 'outstanding',
  'taxa juros mensal (%)': 'ignore', 'cet a.m. (%)': 'ignore', 'cet a.a. (%)': 'ignore', iof: 'ignore',
  'observacoes do contrato': 'note', 'recurso financeiro': 'ignore', parceiro: 'ignore', agente: 'seller',
  'categoria servidor': 'category', secretaria: 'agency', lotacao: 'ignore', cargo: 'ignore', salario: 'ignore',
  'regime de contratacao': 'ignore', 'data de admissao': 'ignore',
  'titular da conta': 'ignore', 'cpf do titular': 'ignore', 'tipo chave pix': 'ignore', 'chave pix': 'ignore', 'digito agencia': 'ignore',
  'comissao base': 'ignore', 'comissao %': 'ignore', 'comissao valor': 'ignore', 'comissao status': 'ignore',
  'mensalidade (contrato)': 'ignore', 'mensalidade ade': 'ignore', 'mensalidade data averbacao': 'ignore',
  'mensalidade valor da ade': 'ignore', 'mensalidade valor anterior': 'ignore', 'mensalidade valor liquido (diferenca)': 'ignore',
  'mensalidade e migracao': 'ignore', 'telefone conjuge': 'ignore',
}

// The PROSESP report from WorkBank ("Gestão de Créditos", owner request 05/10/2026). A title row sits above the header.
// "Operação" is the operation date: it is the only date in the report, so it stands for "Pago ao cliente em".
// "Digitador" is a WorkBank login and "Agente" the company itself, not the team's seller: both are left out, and the
// seller is set in the contract. "Proposta" (WorkBank number) goes to the note; "Contrato" is the ADE.
const PROSESP_COLUMNS: Record<string, ContractField | 'ignore'> = {
  banco: 'ignore', operacao: 'paidOn', proposta: 'note', produto: 'table', bruto: 'requested', liquido: 'released',
  repasse: 'ignore', 'vr. parcela': 'installment', fisico: 'ignore', comissao: 'ignore', digitador: 'ignore', agente: 'ignore',
}
// WorkBank cuts the product name at 20 characters ("PREF. RIO BRANCO EFE").
const PROSESP_TABLES: Record<string, string> = {
  'gov. ac temporario': 'PROSESP - Governo do Acre - Temporário',
  'gov. ac efetivo': 'PROSESP - Governo do Acre - Efetivo',
  'gov. ac comissionado': 'PROSESP - Governo do Acre - Comissionado',
  'pref. rio branco efe': 'PROSESP - Pref. Rio Branco - Efetivo',
  'pref. rio branco efetivo': 'PROSESP - Pref. Rio Branco - Efetivo',
}

export const CONTRACT_LAYOUTS: ContractLayout[] = [
  { key: 'nasp', label: 'NASP', bankName: 'NASP', columns: NASP_COLUMNS },
  { key: 'prosesp', label: 'PROSESP (WorkBank)', bankName: 'PROSESP', columns: PROSESP_COLUMNS, tables: PROSESP_TABLES },
]
export const MAX_CONTRACT_LINES = 500

// Header aliases, compared after normalize(). When several columns feed one field (Telefone and Celular), the first
// non-empty value wins, in the order of this list.
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
  stage: ['etapa', 'status', 'situacao', 'fase'],
  paidOn: ['pago ao cliente em', 'data pagamento', 'data de pagamento', 'pago em', 'data do pagamento', 'data da liberacao'],
  seller: ['vendedor', 'corretor', 'digitador', 'consultor', 'agente'],
  originBank: ['banco de origem', 'banco origem'],
  originContract: ['contrato de origem', 'contrato origem'],
  outstanding: ['saldo devedor', 'saldo'],
  phone: ['celular', 'telefone', 'fone'],
  email: ['e-mail', 'email'],
  note: ['observacao', 'observacoes', 'obs'],
  agreement: ['convenio'],
  category: ['categoria', 'vinculo'],
  birthDate: ['data de nascimento', 'nascimento', 'data nascimento'],
  gender: ['sexo', 'genero'],
  maritalStatus: ['estado civil'],
  birthplace: ['naturalidade'],
  motherName: ['nome da mae', 'mae'],
  fatherName: ['nome do pai', 'pai'],
  rgNumber: ['rg', 'numero do rg'],
  rgIssuer: ['rg orgao emissor', 'orgao emissor', 'orgao expedidor'],
  rgState: ['rg uf', 'uf do rg'],
  rgIssuedOn: ['rg data expedicao', 'data de expedicao', 'data de emissao', 'rg data emissao'],
  whatsapp: ['whatsapp'],
  zip: ['cep'],
  street: ['logradouro', 'endereco', 'rua'],
  number: ['numero'],
  complement: ['complemento'],
  district: ['bairro'],
  city: ['cidade', 'municipio'],
  state: ['uf', 'estado'],
  bankCode: ['banco (codigo)', 'codigo do banco', 'cod banco'],
  bankName: ['banco', 'nome do banco'],
  branch: ['agencia'],
  account: ['conta', 'numero da conta'],
  accountDigit: ['digito conta', 'digito da conta', 'dv conta'],
  accountType: ['tipo de conta'],
  registration: ['matricula'],
  agency: ['orgao', 'secretaria'],
}

// Contract columns: one column each, a second one is refused (two "CPF" columns cannot be guessed).
const SINGLE: ContractField[] = ['cpf', 'table', 'term', 'released', 'requested', 'installment', 'ade']

export const normalize = (s: string) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[*º°ª]/g, ' ').toLowerCase().replace(/\s+/g, ' ').trim()
// Headers keep the ordinal letter: "Data 1ª parcela" is "data 1a parcela", "Nº proposta" is "n proposta".
const headerKey = (s: string) => normalize(s.replace(/ª/g, 'a').replace(/º/g, ''))

const ALIAS_INDEX = new Map<string, { field: ContractField; rank: number }>()
for (const [field, names] of Object.entries(ALIASES) as [ContractField, string[]][])
  names.forEach((n, rank) => ALIAS_INDEX.set(headerKey(n), { field, rank }))

// Columns that look like money but are not recognised: refusing beats ignoring an amount.
const MONEY_HINT = /(valor|saldo|r\$|comiss|repasse|tarifa|iof|seguro|troco)/

export type HeaderIssue = { code: 'missing_column' | 'duplicate_column' | 'unknown_money_column'; column: string }
export type Columns = Partial<Record<ContractField, number[]>>
export type HeaderMap = { columns: Columns; ignored: string[]; issues: HeaderIssue[] }

export function mapContractHeader(header: string[], layout?: ContractLayout): HeaderMap {
  const found: Partial<Record<ContractField, { i: number; rank: number }[]>> = {}
  const ignored: string[] = []
  const issues: HeaderIssue[] = []
  header.forEach((raw, i) => {
    const h = headerKey(raw)
    if (!h) return
    const own = layout?.columns?.[h]
    if (own === 'ignore') { ignored.push(raw.trim()); return }
    const hit = own ? { field: own, rank: -1 } : ALIAS_INDEX.get(h)
    if (!hit) {
      if (MONEY_HINT.test(h)) issues.push({ code: 'unknown_money_column', column: raw.trim() })
      else ignored.push(raw.trim())
      return
    }
    const list = (found[hit.field] ??= [])
    if (SINGLE.includes(hit.field) && list.length) { issues.push({ code: 'duplicate_column', column: raw.trim() }); return }
    list.push({ i, rank: hit.rank })
  })
  const columns: Columns = {}
  for (const [f, list] of Object.entries(found) as [ContractField, { i: number; rank: number }[]][])
    columns[f] = list.sort((a, b) => a.rank - b.rank || a.i - b.i).map(x => x.i)
  for (const f of ['cpf', 'table', 'term'] as const) if (!columns[f]) issues.push({ code: 'missing_column', column: FIELD_LABEL[f] })
  if (!columns.released && !columns.requested) issues.push({ code: 'missing_column', column: 'Valor liberado ou Valor solicitado' })
  return { columns, ignored, issues }
}

export const FIELD_LABEL: Record<ContractField, string> = {
  cpf: 'CPF', name: 'Nome', table: 'Tabela', term: 'Prazo (meses)', released: 'Valor liberado', requested: 'Valor solicitado',
  installment: 'Valor da parcela', ade: 'Nº contrato/ADE', type: 'Tipo', stage: 'Etapa', paidOn: 'Pago ao cliente em',
  seller: 'Vendedor', originBank: 'Banco de origem', originContract: 'Contrato de origem', outstanding: 'Saldo devedor',
  phone: 'Telefone', email: 'E-mail', note: 'Observação', agreement: 'Convênio', category: 'Categoria',
  birthDate: 'Data de nascimento', gender: 'Sexo', maritalStatus: 'Estado civil', birthplace: 'Naturalidade', motherName: 'Nome da mãe',
  fatherName: 'Nome do pai', rgNumber: 'RG', rgIssuer: 'Órgão emissor do RG', rgState: 'UF do RG', rgIssuedOn: 'Data de expedição do RG',
  whatsapp: 'WhatsApp', zip: 'CEP', street: 'Logradouro', number: 'Número', complement: 'Complemento', district: 'Bairro', city: 'Cidade',
  state: 'UF', bankCode: 'Código do banco', bankName: 'Banco', branch: 'Agência', account: 'Conta', accountDigit: 'Dígito da conta',
  accountType: 'Tipo de conta', registration: 'Matrícula', agency: 'Órgão / secretaria',
}

// Contract types by what people write; the value is contract_types.tech_key.
const TYPE_KEYS: Record<string, string> = {
  novo: 'novo', 'contrato novo': 'novo', 'margem livre': 'novo', 'emprestimo novo': 'novo',
  refin: 'refinanciamento', refinanciamento: 'refinanciamento', 'refin normal': 'refinanciamento',
  compra: 'compra_de_divida', 'compra de divida': 'compra_de_divida', 'compra normal': 'compra_de_divida', 'compra divida': 'compra_de_divida',
  portabilidade: 'portabilidade', port: 'portabilidade',
  'refin/portabilidade': 'refin_portabilidade', 'refin portabilidade': 'refin_portabilidade', 'refin de portabilidade': 'refin_portabilidade',
}
// Stages by code, name or common spelling ("credito_liberado" reads as "credito liberado"); the value is the canonical state.
const STAGE_KEYS: Record<string, string> = {
  fila: 'digitization_queue', 'fila de digitacao': 'digitization_queue', 'aguardando digitacao': 'digitization_queue', 'fila digitacao': 'digitization_queue',
  digitando: 'digitizing', 'em digitacao': 'digitizing',
  enviada: 'submitted', 'em analise': 'submitted', 'em analise no banco': 'submitted', digitada: 'submitted', digitado: 'submitted',
  pendencia: 'pending_external', pendente: 'pending_external',
  aprovada: 'approved', aprovado: 'approved',
  paga: 'paid', pago: 'paid', 'credito liberado': 'paid', liberado: 'paid', 'pago ao cliente': 'paid', concretizado: 'paid', concretizada: 'paid',
  // WorkBank (PROSESP): "CR CLIENTE" is the credit paid to the client.
  'cr cliente': 'paid',
  recusada: 'rejected', recusado: 'rejected', reprovada: 'rejected', reprovado: 'rejected',
  cancelada: 'cancelled', cancelado: 'cancelled',
}
const keyOf = (s: string) => normalize(s.replace(/_/g, ' '))

export type LineIssue =
  | 'cpf_required' | 'cpf_invalid' | 'table_required' | 'term_required' | 'term_invalid' | 'amount_required' | 'amount_invalid'
  | 'type_unknown' | 'stage_unknown' | 'paid_on_invalid' | 'paid_on_required'

// What the line adds to the client record. Only filled in empty fields when the client already exists.
export type ClientExtra = {
  profile: Partial<Record<'birth_date' | 'father_name' | 'mother_name' | 'rg_number' | 'rg_issuer' | 'rg_state' | 'rg_issued_on'
    | 'gender' | 'marital_status' | 'birthplace_city' | 'birthplace_state' | 'whatsapp', string>>
  address: { postal_code: string; street: string | null; number: string | null; complement: string | null; neighborhood: string | null; city: string | null; state: string | null } | null
  account: { bank_code: string; bank_name: string; branch: string; account_number: string; account_digit: string | null; account_type: string } | null
  registration: { number: string; agency: string | null } | null
}

export type ContractLine = {
  line: number
  cpf: string; name: string; table: string; term: number | null
  released: string | null; requested: string | null; installment: string | null; outstanding: string | null
  ade: string; typeKey: string | null; stage: string | null; paidOn: string | null
  seller: string; originBank: string; originContract: string; phone: string; email: string; note: string
  client: ClientExtra
  issues: LineIssue[]
  warnings: string[]
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

const GENDER: Record<string, string> = { masculino: 'M', m: 'M', homem: 'M', feminino: 'F', f: 'F', mulher: 'F' }
const MARITAL: [RegExp, string][] = [
  [/^solteir/, 'single'], [/^casad/, 'married'], [/^uniao estavel|^companheir|^amasiad/, 'stable_union'],
  [/^divorciad/, 'divorced'], [/^separad|^desquitad/, 'separated'], [/^viuv/, 'widowed'],
]
const ACCOUNT_TYPE: [RegExp, string][] = [[/^corrente|^cc$/, 'checking'], [/^poupanca|^cp$/, 'savings'], [/^salario/, 'salary'], [/^pagamento/, 'payment']]
const UF = /^[A-Z]{2}$/

// Client fields of one row. Bad values are dropped with a warning: they never block the contract.
function clientExtra(get: (f: ContractField) => string, today: string, warnings: string[]): ClientExtra {
  const profile: ClientExtra['profile'] = {}
  const skip = (f: ContractField) => warnings.push(`${FIELD_LABEL[f]} inválido: não gravado na ficha`)
  const text = (f: ContractField, key: keyof ClientExtra['profile'], min: number, max: number, pattern?: RegExp) => {
    const v = get(f).replace(/\s+/g, ' ').trim()
    if (!v) return
    if (v.length < min || v.length > max || (pattern && !pattern.test(v))) skip(f)
    else profile[key] = v
  }
  const date = (f: ContractField, key: keyof ClientExtra['profile']) => {
    const d = isoDate(get(f))
    if (d === 'invalid' || (d && (d > today || d < '1900-01-01'))) skip(f)
    else if (d) profile[key] = d
  }
  date('birthDate', 'birth_date')
  text('motherName', 'mother_name', 3, 160)
  text('fatherName', 'father_name', 3, 160)
  text('rgNumber', 'rg_number', 3, 20, /^[0-9A-Za-z.\-/ ]+$/)
  text('rgIssuer', 'rg_issuer', 2, 20)
  const rgState = get('rgState').toUpperCase()
  if (rgState) { if (UF.test(rgState)) profile.rg_state = rgState; else skip('rgState') }
  date('rgIssuedOn', 'rg_issued_on')
  const g = normalize(get('gender'))
  if (g) { if (GENDER[g]) profile.gender = GENDER[g]; else skip('gender') }
  const ms = normalize(get('maritalStatus'))
  if (ms) { const hit = MARITAL.find(([re]) => re.test(ms)); if (hit) profile.marital_status = hit[1]; else skip('maritalStatus') }
  // "MANCIO LIMA - AC" or "RIO BRANCO-AC": city and state; "RIO BRANCO": city only.
  const bp = get('birthplace').replace(/\s+/g, ' ').trim()
  if (bp) {
    const m = /^(.*?)\s*[-/]\s*([A-Za-z]{2})$/.exec(bp)
    const city = (m ? m[1] : bp).trim()
    if (city.length >= 2 && city.length <= 120) profile.birthplace_city = city; else skip('birthplace')
    if (m) profile.birthplace_state = m[2].toUpperCase()
  }
  const wa = get('whatsapp').replace(/\D/g, '')
  if (wa) {
    const full = wa.length === 10 || wa.length === 11 ? `55${wa}` : wa
    if (/^55\d{10,11}$/.test(full)) profile.whatsapp = full; else skip('whatsapp')
  }

  let address: ClientExtra['address'] = null
  if (get('zip')) {
    const zip = normalizeCep(get('zip'))
    const state = get('state').toUpperCase()
    const cap = (f: ContractField, n: number) => get(f).replace(/\s+/g, ' ').trim().slice(0, n) || null
    if (!zip) skip('zip')
    else address = { postal_code: zip, street: cap('street', 160), number: cap('number', 20), complement: cap('complement', 80),
      neighborhood: cap('district', 120), city: cap('city', 120), state: UF.test(state) ? state : null }
  }

  let account: ClientExtra['account'] = null
  const number = get('account').replace(/\D/g, '')
  if (number) {
    const code = get('bankCode').replace(/\D/g, '')
    const branch = get('branch').replace(/[^0-9Xx-]/g, '')
    const at = normalize(get('accountType'))
    if (!code || code.length > 3 || !branch) warnings.push('Conta bancária incompleta: não gravada na ficha')
    else account = {
      bank_code: code.padStart(3, '0'), bank_name: get('bankName').slice(0, 120) || code.padStart(3, '0'), branch, account_number: number,
      account_digit: get('accountDigit').replace(/[^0-9Xx]/g, '').toUpperCase() || null,
      account_type: ACCOUNT_TYPE.find(([re]) => re.test(at))?.[1] ?? 'checking',
    }
  }

  const reg = get('registration').replace(/\s+/g, ' ').trim()
  const registration = reg ? { number: reg.slice(0, 40), agency: get('agency').replace(/\s+/g, ' ').trim().slice(0, 160) || null } : null
  return { profile, address, account, registration }
}

// One spreadsheet row into a contract line. `today` (yyyy-mm-dd, Brasília) bounds "Pago ao cliente em".
export function parseContractLine(row: string[], columns: Columns, line: number, today: string): ContractLine {
  const get = (f: ContractField) => {
    for (const i of columns[f] ?? []) { const v = String(row[i] ?? '').trim(); if (v) return v }
    return ''
  }
  const issues: LineIssue[] = []
  const warnings: string[] = []
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
  // Saldo devedor: the first non-zero of its columns ("Saldo por dentro" for a refin, "Quitação externa" for a purchase).
  let outstanding: string | null = null
  for (const i of columns.outstanding ?? []) {
    const v = parseMoneyInput(String(row[i] ?? '').trim())
    if (v === 'invalid') { issues.push('amount_invalid'); break }
    if (v && v !== '0.00') { outstanding = v; break }
  }
  if (!released && !requested && !issues.includes('amount_invalid')) issues.push('amount_required')
  const typeText = keyOf(get('type'))
  const typeKey = typeText ? TYPE_KEYS[typeText] ?? null : null
  if (typeText && !typeKey) issues.push('type_unknown')
  const stageText = keyOf(get('stage'))
  const stage = stageText ? STAGE_KEYS[stageText] ?? null : null
  if (stageText && !stage) issues.push('stage_unknown')
  const paid = isoDate(get('paidOn'))
  const paidOn = paid === 'invalid' ? null : paid
  if (paid === 'invalid' || (paidOn && paidOn > today)) issues.push('paid_on_invalid')
  if (stage === 'paid' && !paidOn && paid !== 'invalid') issues.push('paid_on_required')
  const email = get('email').toLowerCase()
  const validEmail = !email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
  if (!validEmail) warnings.push('E-mail inválido: não gravado na ficha')
  return {
    line, cpf, name: get('name'), table, term, released, requested, installment, outstanding,
    ade: get('ade'), typeKey, stage, paidOn, seller: get('seller'), originBank: get('originBank'), originContract: get('originContract'),
    phone: get('phone'), email: validEmail ? email : '', note: get('note').slice(0, 500),
    client: clientExtra(get, today, warnings), issues, warnings,
  }
}

// The whole sheet, blank lines skipped. The header is the first row with a CPF column among the first five (a report
// title may sit above it); without one, the first row, so its missing columns are reported.
export function parseContractSheet(rows: string[][], today: string, layout?: ContractLayout) {
  const found = rows.slice(0, 5).findIndex(r => mapContractHeader(r, layout).columns.cpf)
  const at = found < 0 ? 0 : found
  const header = rows[at] ?? []
  const body = rows.slice(at + 1)
  const map = mapContractHeader(header, layout)
  if (map.issues.length) return { map, lines: [] as ContractLine[], tooMany: false }
  const tooMany = body.length > MAX_CONTRACT_LINES
  const lines = body.slice(0, MAX_CONTRACT_LINES).map((r, i) => {
    const line = parseContractLine(r, map.columns, at + i + 2, today)
    const table = layout?.tables?.[normalize(line.table)]
    return table ? { ...line, table } : line
  })
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
