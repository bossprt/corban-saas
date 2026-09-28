// Sales CRM (V2): lead stages, labels and the spreadsheet mapping of a campaign import. Pure functions, no I/O.

export const LEAD_STAGES = ['new', 'contacted', 'negotiating', 'proposal', 'won', 'lost'] as const
export type LeadStage = (typeof LEAD_STAGES)[number]
export const STAGE_LABEL: Record<LeadStage, string> = {
  new: 'Novo', contacted: 'Em contato', negotiating: 'Negociando', proposal: 'Proposta', won: 'Ganho', lost: 'Perdido',
}
// Badge tones (same names as the design system's Tone).
export const STAGE_TONE: Record<LeadStage, 'neutral' | 'pending' | 'paid-out' | 'received' | 'reversed'> = {
  new: 'neutral', contacted: 'pending', negotiating: 'paid-out', proposal: 'received', won: 'received', lost: 'reversed',
}
// "proposal" and "won" follow the client's proposal in the database; a seller moves only these by hand.
export const MANUAL_STAGES: readonly LeadStage[] = ['new', 'contacted', 'negotiating', 'lost']
export const OPEN_STAGES: readonly LeadStage[] = ['new', 'contacted', 'negotiating', 'proposal']
export const isLeadStage = (v: unknown): v is LeadStage => typeof v === 'string' && (LEAD_STAGES as readonly string[]).includes(v)
export const stageLabel = (v: string) => (isLeadStage(v) ? STAGE_LABEL[v] : v)

export const DISTRIBUTIONS = ['queue', 'round_robin', 'manual'] as const
export type Distribution = (typeof DISTRIBUTIONS)[number]
export const DISTRIBUTION_LABEL: Record<Distribution, string> = {
  queue: 'Fila: o vendedor pega o próximo',
  round_robin: 'Rodízio automático entre os vendedores da campanha',
  manual: 'Supervisor distribui',
}
export const isDistribution = (v: unknown): v is Distribution => typeof v === 'string' && (DISTRIBUTIONS as readonly string[]).includes(v)

export const CHANNEL_LABEL: Record<string, string> = {
  whatsapp: 'WhatsApp', meta_ads: 'Meta Ads', api: 'Integração', import: 'Planilha', manual: 'Cadastro manual', referral: 'Indicação', other: 'Outro',
}

// WhatsApp link from a stored phone (digits with 55). The phone goes to wa.me, never a CPF.
export function whatsappHref(phone: string | null | undefined): string | null {
  const d = String(phone ?? '').replace(/\D/g, '')
  if (/^55\d{10,11}$/.test(d)) return `https://wa.me/${d}`
  if (/^\d{10,11}$/.test(d)) return `https://wa.me/55${d}`
  return null
}

// Campaign spreadsheet: the operator says which column is the name, CPF, phones and e-mail; any other column they tick
// travels as text (margin, bank, benefit...). Values stay text: nothing here is money arithmetic.
export const CAMPAIGN_FIELDS = ['name', 'cpf', 'phone', 'phone2', 'email'] as const
export type CampaignField = (typeof CAMPAIGN_FIELDS)[number]
export const CAMPAIGN_FIELD_LABEL: Record<CampaignField, string> = { name: 'Nome', cpf: 'CPF', phone: 'Telefone', phone2: 'Telefone 2', email: 'E-mail' }
export type CampaignMapping = Partial<Record<CampaignField, number>> & { info?: number[] }
export type CampaignRow = { name?: string; cpf?: string; phone?: string; phone2?: string; email?: string; info?: Record<string, string> }

export const CAMPAIGN_LIMITS = { rows: 20_000, chunk: 1000, infoColumns: 30, infoValue: 200 } as const

const HINTS: Record<CampaignField, RegExp> = {
  name: /^(nome|cliente|nome do cliente|nome completo|benefici[aá]rio)$/i,
  cpf: /cpf/i,
  phone: /^(telefone|celular|fone|whats(app)?|telefone ?1|celular ?1|tel)$/i,
  phone2: /^(telefone ?2|celular ?2|fone ?2|tel ?2)$/i,
  email: /e-?mail/i,
}

// First guess of the mapping from the header names; the operator confirms it on screen.
export function guessCampaignMapping(headers: string[]): CampaignMapping {
  const out: CampaignMapping = {}
  const used = new Set<number>()
  for (const f of CAMPAIGN_FIELDS) {
    const i = headers.findIndex((h, idx) => !used.has(idx) && HINTS[f].test(h.trim()))
    if (i >= 0) { out[f] = i; used.add(i) }
  }
  return out
}

export function buildCampaignRows(headers: string[], body: string[][], mapping: CampaignMapping): CampaignRow[] {
  const info = (mapping.info ?? []).filter(i => i >= 0 && i < headers.length).slice(0, CAMPAIGN_LIMITS.infoColumns)
  const cell = (r: string[], i: number | undefined) => (i === undefined || i < 0 ? '' : String(r[i] ?? '').trim())
  return body
    .map(r => {
      const row: CampaignRow = {}
      for (const f of CAMPAIGN_FIELDS) { const v = cell(r, mapping[f]); if (v) row[f] = v.slice(0, 200) }
      const extra: Record<string, string> = {}
      for (const i of info) {
        const v = cell(r, i)
        const k = (headers[i] || `Coluna ${i + 1}`).trim().slice(0, 60)
        if (v) extra[k] = v.slice(0, CAMPAIGN_LIMITS.infoValue)
      }
      if (Object.keys(extra).length) row.info = extra
      return row
    })
    .filter(r => r.name || r.cpf || r.phone || r.phone2)
}

export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}

// "2026-09-28T14:00" (datetime-local, Brasília) to an ISO instant; null when empty or invalid.
export function localDateTimeToIso(v: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v)) return null
  const d = new Date(`${v}:00-03:00`)
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}
