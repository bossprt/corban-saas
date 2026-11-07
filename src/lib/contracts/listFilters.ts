// Filters of the Contratos and Esteira lists, read from the address and checked before they reach the database
// (contract_list / pipeline_case_list, migration 20261107001252). Anything malformed is dropped, so a bad link shows the
// list without that filter instead of an error. The search text is folded in the database (no accents, no case).

const DAY = /^\d{4}-\d{2}-\d{2}$/
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CPF_LIKE = /^\s*\d{3}\.?\d{3}\.?\d{3}-?\d{2}\s*$/

// A real calendar day (2026-02-30 is not): the database would refuse it.
export const isDay = (v: string) => { if (!DAY.test(v)) return false; const d = new Date(`${v}T12:00:00Z`); return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v }
const day = (v: string) => (isDay(v) ? v : '')
const uuid = (v: string) => (UUID.test(v) ? v.toLowerCase() : '')
// A uuid, or "none" where the list offers "Sem banco" / "Sem vendedor".
const uuidOrNone = (v: string) => (v === 'none' ? 'none' : uuid(v))

// The search box: a name or contract number. A CPF never travels in the address (CpfSearchForm turns it into
// cliente=<id>), so one that still arrives is ignored.
export function listSearch(raw: string): string {
  const t = raw.replace(/\s+/g, ' ').trim().slice(0, 80)
  return CPF_LIKE.test(t) ? '' : t
}

export type ContractFilters = {
  q: string; de: string; ate: string; banco: string; convenio: string; vendedor: string; grupo: string; situacao: string; cliente: string
  comissao: string; alterado: string; desatualizado: string; repasse: string; pago_de: string; pago_ate: string; encerradas: string
}

const REPASSE = ['aguardando', 'banco', 'gratificacao', 'divergente', 'creditado', 'pago', 'sem_repasse', 'concluido']

export function contractFilters(get: (k: string) => string, situacao: string): ContractFilters {
  return {
    q: listSearch(get('q')),
    de: day(get('de')), ate: day(get('ate')),
    banco: uuidOrNone(get('banco')), convenio: uuid(get('convenio')), vendedor: uuidOrNone(get('vendedor')), grupo: uuid(get('grupo')),
    situacao, cliente: uuid(get('cliente')),
    comissao: ['calculada', 'pendente'].includes(get('comissao')) ? get('comissao') : '',
    alterado: get('alterado') ? '1' : '', desatualizado: get('desatualizado') ? '1' : '',
    repasse: REPASSE.includes(get('repasse')) ? get('repasse') : '',
    pago_de: day(get('pago_de')), pago_ate: day(get('pago_ate')),
    encerradas: get('encerradas') === '1' ? '1' : '',
  }
}

export type PipelineFilters = { q: string; cliente: string; vendedor: string }

export function pipelineFilters(get: (k: string) => string): PipelineFilters {
  return { q: listSearch(get('q')), cliente: uuid(get('cliente')), vendedor: uuidOrNone(get('vendedor')) }
}

// How many of the optional filters are on (the phone shows it on the "Filtros" button).
export const activeCount = (f: Record<string, string>, skip: string[] = []) => Object.entries(f).filter(([k, v]) => !skip.includes(k) && v !== '').length
