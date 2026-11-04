import { normalize } from './contract-layout'

// Bevicred "produção sintética" (webservice, assunto PRODUCAOSINTETICO) as contract lines (owner request 03/11/2026).
// One call per import day returns every bank's contracts in the same shape; the same contract (ADE) comes again on the
// days its status changes, so the latest status wins. The fields come from the probe of 03/11 (dates yyyy-mm-dd, money
// with a decimal point, CPF with dots). "tabela" is the bank's table name plus the term ("... WEB 108X"), the same name
// the company's Bevicred tables carry; it is empty on many lines, and "descricaoOperacao" (product + Bevicred table)
// is always there, so it is the key the owner's table choice is remembered by. Address and bank account come without
// CEP or bank code and the marital status as a number, so they are left out; the client record gets what is complete.

export type BevicredRow = {
  financeira?: string | null; numeroAde?: string | null; cpfCliente?: string | null; nomeCliente?: string | null
  tabela?: string | null; status?: string | null; dataPagtoCliente?: string | null; dataStatus?: string | null
  prazo?: string | null; valoremprestimo?: string | null; valorLiquido?: string | null; vlrParcela?: string | null
  nomeFormaContrato?: string | null; descricaoOperacao?: string | null; codigoParceiro?: string | null; nomeParceiro?: string | null
  dataNascimento?: string | null; nomeMae?: string | null; nomePai?: string | null; rg?: string | null
  celular?: string | null; fone?: string | null; beneficio?: string | null; nomeConvenio?: string | null
}

// What the line carries besides the contract: shown on screen and used to remember the owner's choices.
export type BevicredMeta = {
  credential: string; institution: string; operation: string; operationKey: string; tableName: string
  partnerCode: string; partnerName: string; status: string
}

const text = (v: unknown) => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim() : '')

// Bevicred status -> the stage name the contract import understands (owner, 03/11/2026).
export function bevicredStage(status: string): string {
  const s = normalize(status)
  if (s === 'pago') return 'Paga'
  if (s === 'cancelado') return 'Cancelada'
  if (s === 'pendente') return 'Pendência'
  return 'Em análise no banco'
}

// "C6 BANK NOVO INSS ML TKT ATE 6K WEB 108X" is the table "C6 BANK NOVO INSS ML TKT ATE 6K WEB".
export const bevicredTableName = (s: string) => text(s).replace(/\s+\d{1,3}\s*X$/i, '').trim()

// "C6 BANK" and "C6 Bank", "BANCO DAYCOVAL" and "Daycoval": the same bank.
const bankCore = (s: string) => normalize(s).replace(/\b(banco|bank|s\.?a\.?)\b/g, ' ').replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim()
export const sameBank = (bevicred: string, corban: string) => !!bankCore(bevicred) && bankCore(bevicred) === bankCore(corban)

// The same ADE on several days: the latest status date wins (ties keep the later row).
export function latestByAde<T extends { row: BevicredRow }>(rows: T[]): T[] {
  const best = new Map<string, T>()
  const loose: T[] = []
  for (const r of rows) {
    const ade = text(r.row.numeroAde)
    if (!ade) { loose.push(r); continue }
    const prev = best.get(ade)
    if (!prev || text(r.row.dataStatus) >= text(prev.row.dataStatus)) best.set(ade, r)
  }
  return [...best.values(), ...loose]
}

const HEADER = ['CPF', 'Nome', 'Tabela', 'Prazo', 'Valor solicitado', 'Valor liberado', 'Valor da parcela', 'Nº contrato/ADE', 'Tipo',
  'Etapa', 'Pago ao cliente em', 'Data de nascimento', 'Nome da mãe', 'Nome do pai', 'RG', 'Celular', 'Matrícula', 'Órgão']

// The rows as a sheet the contract import reads (Corban template headers), and the meta of each line in the same order.
export function bevicredSheet(rows: { credential: string; row: BevicredRow }[]): { rows: string[][]; meta: BevicredMeta[] } {
  const sheet: string[][] = [HEADER]
  const meta: BevicredMeta[] = []
  for (const { credential, row: r } of latestByAde(rows)) {
    const status = text(r.status)
    const stage = bevicredStage(status)
    // A paid line without "dataPagtoCliente" uses the date its status changed to paid.
    const paidOn = stage === 'Paga' ? text(r.dataPagtoCliente) || text(r.dataStatus) : text(r.dataPagtoCliente)
    // A blank or "0" amount is not informed (the synthetic report sends null for some banks).
    const money = (v: unknown) => { const t = text(v); return /^0+(\.0+)?$/.test(t) ? '' : t }
    const benefit = text(r.beneficio)
    sheet.push([
      text(r.cpfCliente), text(r.nomeCliente), bevicredTableName(text(r.tabela)), text(r.prazo), money(r.valoremprestimo),
      money(r.valorLiquido), money(r.vlrParcela), text(r.numeroAde), text(r.nomeFormaContrato), stage, paidOn,
      text(r.dataNascimento), text(r.nomeMae), text(r.nomePai), text(r.rg), text(r.celular) || text(r.fone),
      benefit, benefit ? text(r.nomeConvenio) : '',
    ])
    const operation = text(r.descricaoOperacao)
    meta.push({
      credential, institution: text(r.financeira), operation, operationKey: normalize(operation), tableName: bevicredTableName(text(r.tabela)),
      partnerCode: text(r.codigoParceiro), partnerName: text(r.nomeParceiro), status: status || 'sem status',
    })
  }
  return { rows: sheet, meta }
}
