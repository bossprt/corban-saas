'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { xlsxRows } from '@/lib/commercial-xlsx'
import { parseMoneyInput } from '@/lib/money-input'
import {
  CONTRACT_LAYOUTS, MAX_CONTRACT_LINES, matchTable, normalize, parseContractSheet,
  type ContractLine, type HeaderIssue, type LineIssue,
} from '@/lib/imports/contract-layout'

type Ctx = Awaited<ReturnType<typeof requireAppContext>>

export type PreviewLine = {
  line: number; cpf: string; name: string; table: string; term: number | null; amount: string | null
  ade: string; stage: string | null; seller: string
  status: 'ok' | 'exists' | 'error'; messages: string[]
}
export type ImportResult = {
  error?: string
  fileIssues: string[]; ignored: string[]; tooMany: boolean
  lines: PreviewLine[]
  done?: { created: number; existed: number; failed: number }
}

const LINE_MESSAGE: Record<LineIssue, string> = {
  cpf_required: 'CPF vazio', cpf_invalid: 'CPF inválido', table_required: 'Tabela vazia', term_required: 'Prazo vazio',
  term_invalid: 'Prazo inválido', amount_required: 'Sem valor liberado nem solicitado', amount_invalid: 'Valor em formato inválido',
  type_unknown: 'Tipo não reconhecido', stage_unknown: 'Etapa não reconhecida', paid_on_invalid: 'Data de pagamento inválida ou futura',
  paid_on_required: 'Etapa Paga sem "Pago ao cliente em"',
}
const HEADER_MESSAGE: Record<HeaderIssue['code'], (c: string) => string> = {
  missing_column: c => `Falta a coluna "${c}"`,
  duplicate_column: c => `Coluna repetida: "${c}"`,
  unknown_money_column: c => `Coluna de valor não reconhecida: "${c}" (apague ou renomeie para um campo do modelo)`,
}
const STAGE_LABEL: Record<string, string> = {
  digitization_queue: 'Aguardando digitação', digitizing: 'Em digitação', submitted: 'Em análise no banco', pending_external: 'Pendência',
  approved: 'Aprovada', paid: 'Paga', rejected: 'Recusada', cancelled: 'Cancelada',
}

// Same as a contract typed on the screen: without a seller the commission waits until one is set in the contract.
const NO_SELLER = 'Sem vendedor: a comissão é calculada quando você informar o vendedor no contrato'

const todayBr = () => new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 10)

type Resolved = {
  line: ContractLine
  versionId?: string; tableName?: string; typeId?: string; sellerId?: string | null; stageId?: string; clientId?: string
  status: PreviewLine['status']; messages: string[]
}

// Reads the file and checks every line against the company's catalog. Nothing is written here.
async function resolve(ctx: Ctx, formData: FormData): Promise<{ result: ImportResult; resolved: Resolved[] }> {
  const { supabase, organization } = ctx
  const empty: ImportResult = { fileIssues: [], ignored: [], tooMany: false, lines: [] }
  const layout = CONTRACT_LAYOUTS.find(l => l.key === String(formData.get('layout') ?? ''))
  const file = formData.get('file')
  if (!layout) return { result: { ...empty, error: 'Escolha o layout.' }, resolved: [] }
  if (!(file instanceof File) || file.size === 0) return { result: { ...empty, error: 'Escolha a planilha (.xlsx).' }, resolved: [] }
  if (!/\.xlsx$/i.test(file.name)) return { result: { ...empty, error: 'A planilha precisa ser .xlsx (Excel).' }, resolved: [] }

  let rows: string[][]
  try { rows = await xlsxRows(Buffer.from(await file.arrayBuffer()), MAX_CONTRACT_LINES + 2) }
  catch { return { result: { ...empty, error: 'Não consegui ler a planilha. Salve como .xlsx e tente de novo.' }, resolved: [] } }
  const today = todayBr()
  const sheet = parseContractSheet(rows, today)
  const result: ImportResult = {
    fileIssues: sheet.map.issues.map(i => HEADER_MESSAGE[i.code](i.column)),
    ignored: sheet.map.ignored, tooMany: sheet.tooMany, lines: [],
  }
  if (result.fileIssues.length) return { result, resolved: [] }
  if (sheet.lines.length === 0) return { result: { ...result, error: 'A planilha não tem linhas de contrato.' }, resolved: [] }

  const cpfs = [...new Set(sheet.lines.map(l => l.cpf).filter(Boolean))]
  const [{ data: catalog }, { data: types }, { data: sellers }, { data: stages }, { data: banks }, { data: clients }] = await Promise.all([
    supabase.rpc('proposal_catalog', { p_org: organization.id, p_keep: null }),
    supabase.from('contract_types').select('id,tech_key,organization_id').eq('is_active', true),
    supabase.from('commercial_sellers').select('id,name').eq('is_active', true),
    supabase.from('operational_stages').select('id,canonical_state,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('organization_banks').select('id,name,tech_key').eq('name', layout.bankName),
    supabase.from('clients').select('id,cpf').in('cpf', cpfs).is('deleted_at', null),
  ])
  const bank = (banks ?? [])[0] as { id: string; name: string; tech_key: string | null } | undefined
  if (!bank) return { result: { ...result, error: `O banco ${layout.bankName} não está cadastrado.` }, resolved: [] }

  type CatRow = { version_id: string; table_name: string; bank_id: string; contract_type_id: string | null }
  const tables = new Map<string, { versionId: string; name: string; types: string[] }>()
  for (const r of (catalog ?? []) as CatRow[]) {
    if (r.bank_id !== bank.id) continue
    const t = tables.get(r.version_id) ?? { versionId: r.version_id, name: r.table_name, types: [] }
    if (r.contract_type_id && !t.types.includes(r.contract_type_id)) t.types.push(r.contract_type_id)
    tables.set(r.version_id, t)
  }
  const tableList = [...tables.values()]
  // Term ranges of each line of those tables, when this user can read them; otherwise the bank's own check applies.
  const { data: conds } = tableList.length
    ? await supabase.from('commercial_conditions').select('product_table_version_id,contract_type_id,term_min,term_max').in('product_table_version_id', tableList.map(t => t.versionId))
    : { data: [] }
  const typeByKey = new Map<string, string>()
  for (const t of (types ?? []) as { id: string; tech_key: string; organization_id: string | null }[])
    if (!typeByKey.has(t.tech_key) || t.organization_id) typeByKey.set(t.tech_key, t.id)
  const sellerByName = new Map<string, string[]>()
  for (const s of (sellers ?? []) as { id: string; name: string }[]) sellerByName.set(normalize(s.name), [...(sellerByName.get(normalize(s.name)) ?? []), s.id])
  const stageByState = new Map<string, string>()
  for (const s of (stages ?? []) as { id: string; canonical_state: string }[]) if (!stageByState.has(s.canonical_state)) stageByState.set(s.canonical_state, s.id)
  const clientByCpf = new Map(((clients ?? []) as { id: string; cpf: string }[]).map(c => [c.cpf, c.id]))

  // Already in Corban: same bank + ADE.
  const ades = [...new Set(sheet.lines.map(l => l.ade).filter(Boolean))]
  const { data: known } = ades.length
    ? await supabase.from('proposal_external_identities').select('external_proposal_number,institution_key').in('external_proposal_number', ades)
    : { data: [] }
  const bankKey = (bank.tech_key ?? bank.name).toLowerCase()
  const knownAde = new Set(((known ?? []) as { external_proposal_number: string; institution_key: string }[])
    .filter(k => k.institution_key.toLowerCase() === bankKey).map(k => k.external_proposal_number))
  // Without ADE: the same client, table, term and amount already registered counts as the same contract.
  const clientIds = [...clientByCpf.values()]
  const { data: existing } = clientIds.length
    ? await supabase.from('proposals_v2').select('customer_id,product_table_version_id,term,released_amount,requested_amount,status').in('customer_id', clientIds)
    : { data: [] }
  // Amounts compared as exact decimal text ("1500.00"), never as floats.
  const exact = (v: string | number | null) => { const m = v === null ? null : parseMoneyInput(String(v)); return m === 'invalid' ? null : m }
  const sameKey = (c: string, v: string, term: number | null, rel: string | null, req: string | null) => `${c}|${v}|${term}|${rel ?? ''}|${req ?? ''}`
  const existingKeys = new Set(((existing ?? []) as { customer_id: string; product_table_version_id: string; term: number | null; released_amount: string | number | null; requested_amount: string | number | null; status: string }[])
    .filter(p => p.status !== 'cancelled')
    .map(p => sameKey(p.customer_id, p.product_table_version_id, p.term,
      exact(p.released_amount), exact(p.requested_amount))))

  const seenInFile = new Set<string>()
  const resolved: Resolved[] = sheet.lines.map(line => {
    const messages = line.issues.map(i => LINE_MESSAGE[i])
    const r: Resolved = { line, status: 'ok', messages }
    if (line.cpf && !clientByCpf.has(line.cpf) && line.name.trim().length < 3) messages.push('Cliente novo sem Nome')
    if (line.table) {
      const t = matchTable(line.table, tableList)
      if (t === 'none') messages.push(`Tabela "${line.table}" não encontrada no ${bank.name}`)
      else if (t === 'ambiguous') messages.push(`Tabela "${line.table}" bate com mais de uma tabela do ${bank.name}`)
      else {
        r.versionId = t.versionId; r.tableName = t.name
        if (line.typeKey) {
          const id = typeByKey.get(line.typeKey)
          if (!id || !t.types.includes(id)) messages.push('Tipo de contrato não existe nessa tabela')
          else r.typeId = id
        } else if (t.types.length === 1) r.typeId = t.types[0]
        else messages.push('Informe o Tipo (a tabela tem mais de um tipo de contrato)')
        if (r.typeId && line.term) {
          const lines = ((conds ?? []) as { product_table_version_id: string; contract_type_id: string; term_min: number; term_max: number }[])
            .filter(c => c.product_table_version_id === t.versionId && c.contract_type_id === r.typeId)
          if (lines.length && !lines.some(c => line.term! >= c.term_min && line.term! <= c.term_max))
            messages.push(`Prazo ${line.term} fora da tabela (${lines.map(c => `${c.term_min} a ${c.term_max}`).join(', ')})`)
        }
      }
    }
    if (line.seller) {
      const ids = sellerByName.get(normalize(line.seller)) ?? []
      if (ids.length === 1) r.sellerId = ids[0]
      else messages.push(ids.length ? `Vendedor "${line.seller}" com nome repetido na equipe` : `Vendedor "${line.seller}" não encontrado`)
    }
    if (line.stage) {
      r.stageId = stageByState.get(line.stage)
      if (!r.stageId) messages.push('Etapa não existe na esteira')
    }
    r.clientId = clientByCpf.get(line.cpf)
    if (messages.length) { r.status = 'error'; return r }
    const fileKey = line.ade ? `ade:${line.ade}` : `k:${line.cpf}|${r.versionId}|${line.term}|${line.released ?? ''}|${line.requested ?? ''}`
    if (seenInFile.has(fileKey)) { r.status = 'error'; messages.push('Linha repetida na planilha'); return r }
    seenInFile.add(fileKey)
    if ((line.ade && knownAde.has(line.ade)) || (!line.ade && r.clientId && existingKeys.has(sameKey(r.clientId, r.versionId!, line.term, line.released, line.requested)))) {
      r.status = 'exists'; messages.push('Já cadastrado no Corban (não será alterado)')
    } else if (!r.sellerId) messages.push(NO_SELLER)
    return r
  })
  result.lines = resolved.map(({ line: l, tableName, status, messages }) => ({
    line: l.line, cpf: l.cpf, name: l.name, table: tableName ?? l.table, term: l.term, amount: l.released ?? l.requested,
    ade: l.ade, stage: l.stage ? STAGE_LABEL[l.stage] ?? l.stage : null, seller: l.seller, status, messages,
  }))
  return { result, resolved }
}

export async function previewContracts(formData: FormData): Promise<ImportResult> {
  const ctx = await requireAppContext()
  if (!can(ctx.access, 'propostas.create')) return { error: 'Sem permissão para cadastrar contratos.', fileIssues: [], ignored: [], tooMany: false, lines: [] }
  return (await resolve(ctx, formData)).result
}

const RPC_MESSAGE: [RegExp, string][] = [
  [/invalid_cpf/, 'CPF inválido'], [/full_name_required/, 'Cliente novo sem Nome'], [/invalid_email/, 'E-mail inválido'],
  [/invalid_ade|ade_required/, 'Nº contrato/ADE inválido'], [/invalid_amount|amount_required/, 'Valor inválido'], [/invalid_term/, 'Prazo inválido'],
  [/contract_type_not_in_table|contract_type_not_found/, 'Tipo de contrato não existe nessa tabela'],
  [/invalid_outstanding_balance|invalid_origin/, 'Saldo devedor inválido'], [/invalid_paid_on/, 'Data de pagamento inválida'],
  [/not_authorized|forbidden/, 'Sem permissão'],
]
const rpcMessage = (m: string | undefined) => RPC_MESSAGE.find(([re]) => re.test(m ?? ''))?.[1] ?? 'Erro ao gravar'

// Writes the lines that passed the check, one by one, each through the same RPCs as the screens. A line that fails
// does not stop the others; the result says what happened to each.
export async function importContracts(formData: FormData): Promise<ImportResult> {
  const ctx = await requireAppContext()
  if (!can(ctx.access, 'propostas.create') || !can(ctx.access, 'clientes.create'))
    return { error: 'Sem permissão para cadastrar contratos e clientes.', fileIssues: [], ignored: [], tooMany: false, lines: [] }
  const { result, resolved } = await resolve(ctx, formData)
  if (result.error || result.fileIssues.length) return result
  if (resolved.some(r => r.status === 'error')) return { ...result, error: 'Corrija as linhas com erro antes de importar.' }
  const { supabase, organization } = ctx
  const done = { created: 0, existed: 0, failed: 0 }
  for (const [i, r] of resolved.entries()) {
    const out = result.lines[i]
    if (r.status === 'exists') { done.existed++; continue }
    const l = r.line
    const { data: client, error: clientError } = await supabase.rpc('upsert_client', {
      p_org: organization.id, p_cpf: l.cpf, p_full_name: l.name || null, p_phone: l.phone || null, p_email: l.email || null, p_source: 'import',
    })
    const clientId = (Array.isArray(client) ? client[0] : client)?.client_id as string | undefined
    if (clientError || !clientId) { done.failed++; out.status = 'error'; out.messages = [rpcMessage(clientError?.message)]; continue }
    const details: Record<string, string> = {}
    if (l.outstanding) details.outstanding_balance = l.outstanding
    if (l.originBank) details.origin_bank_name = l.originBank.slice(0, 120)
    if (l.originContract) details.origin_contract_number = l.originContract.slice(0, 60)
    const { data, error } = await supabase.rpc('create_direct_proposal', {
      p_org: organization.id, p_customer_id: clientId, p_table_version_id: r.versionId, p_seller_id: r.sellerId ?? null,
      p_requested_amount: l.requested, p_released_amount: l.released, p_installment_amount: l.installment, p_term: l.term,
      p_ade: l.ade || null, p_stage: l.ade ? 'submitted' : 'digitization_queue', p_contract_type_id: r.typeId,
      p_details: Object.keys(details).length ? details : null,
    })
    const row = (Array.isArray(data) ? data[0] : data) as { proposal_id: string; duplicate: boolean } | null
    if (error || !row) { done.failed++; out.status = 'error'; out.messages = [rpcMessage(error?.message)]; continue }
    if (row.duplicate) { done.existed++; out.status = 'exists'; out.messages = ['Já cadastrado no Corban (não foi alterado)']; continue }
    done.created++
    const tail = r.sellerId ? [] : [NO_SELLER]
    out.messages = ['Cadastrado', ...tail]
    const initial = l.ade ? 'submitted' : 'digitization_queue'
    if (r.stageId && l.stage !== initial) {
      const { data: kase } = await supabase.from('operational_cases').select('id').eq('proposal_id', row.proposal_id).maybeSingle()
      const { error: moveError } = kase
        ? await supabase.rpc('move_case_to_stage', { p_case_id: kase.id, p_stage_id: r.stageId, p_note: l.note || null, p_pendency_due_at: null, p_paid_on: l.paidOn })
        : { error: { message: 'case_not_found' } }
      out.messages = moveError ? [`Cadastrado, mas a etapa não mudou (${rpcMessage(moveError.message)})`, ...tail] : ['Cadastrado', ...tail]
    }
  }
  revalidatePath('/app/propostas')
  return { ...result, done }
}
