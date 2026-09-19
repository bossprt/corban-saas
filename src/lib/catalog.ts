// Catalog / setup helpers (pure). Nothing here invents commercial data: rates, coefficients, terms and documents are always typed by the organization.

// The esteira states are part of the DOMAIN (transition_operational_case and send_proposal_to_digitization need an ACTIVE stage for each target state).
// "paid" is deliberately absent: it is only ever reached through the evidence path, never by a person moving a case.
export const STANDARD_STAGES: { code: string; name: string; state: string; sort: number }[] = [
  { code: 'fila_digitacao', name: 'Fila de digitação', state: 'digitization_queue', sort: 0 },
  { code: 'digitando', name: 'Em digitação', state: 'digitizing', sort: 1 },
  { code: 'enviada', name: 'Enviada ao banco', state: 'submitted', sort: 2 },
  { code: 'aguardando_banco', name: 'Aguardando retorno do banco', state: 'pending_external', sort: 3 },
  { code: 'aprovada', name: 'Aprovada', state: 'approved', sort: 4 },
  { code: 'recusada', name: 'Recusada', state: 'rejected', sort: 5 },
  { code: 'cancelada', name: 'Cancelada', state: 'cancelled', sort: 6 },
]
export const REQUIRED_STAGE_STATES = STANDARD_STAGES.map(s => s.state)

export function missingStages(existingStates: readonly string[]) {
  const have = new Set(existingStates)
  return STANDARD_STAGES.filter(s => !have.has(s.state))
}

const dec = (v: FormDataEntryValue | null): number | null | 'invalid' => {
  const t = String(v ?? '').trim().replace(',', '.')
  if (t === '') return null
  const n = Number(t)
  return Number.isFinite(n) && n >= 0 && n < 1e6 ? n : 'invalid'
}
const int = (v: FormDataEntryValue | null): number | null | 'invalid' => {
  const t = String(v ?? '').trim()
  if (t === '') return null
  return /^\d{1,4}$/.test(t) && Number(t) > 0 ? Number(t) : 'invalid'
}

export type VersionInput = { rate: number | null; coefficient: number | null; termMin: number | null; termMax: number | null }
export function parseVersionForm(f: FormData): VersionInput | null {
  const rate = dec(f.get('rate')), coefficient = dec(f.get('coefficient')), termMin = int(f.get('term_min')), termMax = int(f.get('term_max'))
  if (rate === 'invalid' || coefficient === 'invalid' || termMin === 'invalid' || termMax === 'invalid') return null
  if (rate === null && coefficient === null) return null
  if (termMin !== null && termMax !== null && termMin > termMax) return null
  return { rate, coefficient, termMin, termMax }
}

export const isCode = (v: unknown): v is string => typeof v === 'string' && /^[A-Za-z0-9_.-]{1,40}$/.test(v)
export const isLabel = (v: unknown, max = 120): v is string => typeof v === 'string' && v.trim().length >= 1 && v.trim().length <= max

// Setup checklist for the organization admin: deterministic, computed from real rows only.
export type SetupInput = {
  activeMembers: number; routes: number; publishedVersions: number; publishedChecklists: number; stageStates: readonly string[]; referenceReady: boolean
}
export type SetupItem = { key: string; label: string; done: boolean; hint: string; href: string }
export function setupItems(i: SetupInput): SetupItem[] {
  const missing = missingStages(i.stageStates).length
  return [
    { key: 'team', label: 'Equipe convidada', done: i.activeMembers >= 2, hint: 'Convide o supervisor e os operadores.', href: '/app/equipe' },
    { key: 'reference', label: 'Catálogo de referência carregado (bancos, produtos, documentos)', done: i.referenceReady, hint: 'Feito pelo administrador da plataforma; sem isso não há rotas.', href: '/app/catalogo' },
    { key: 'routes', label: 'Rota comercial criada', done: i.routes > 0, hint: 'Escolha banco, convênio, produto e modalidade.', href: '/app/catalogo' },
    { key: 'table', label: 'Tabela com versão publicada', done: i.publishedVersions > 0, hint: 'Sem tabela publicada ninguém consegue simular.', href: '/app/catalogo' },
    { key: 'checklist', label: 'Checklist de documentos publicado', done: i.publishedChecklists > 0, hint: 'Sem checklist publicado o operador não prepara documentos.', href: '/app/catalogo' },
    { key: 'stages', label: 'Etapas da operação configuradas', done: missing === 0, hint: missing ? `Faltam ${missing} etapa(s); use "Criar etapas padrão".` : 'Todas as etapas existem.', href: '/app/catalogo' },
  ]
}
