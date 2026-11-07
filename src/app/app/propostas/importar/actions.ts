'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { xlsxRows } from '@/lib/commercial-xlsx'
import { csvRows } from '@/lib/imports/csv'
import { enrichClient } from '@/lib/imports/client-enrich'
import { parseMoneyInput } from '@/lib/money-input'
import { reportMove } from '@/lib/imports/report-move'
import { extractPdfItems } from '@/lib/imports/smart-pdf'
import { PDF_ERRORS, valorPdfSheet, type ValorProduct } from '@/lib/imports/valor-pdf'
import { bevicredSheet, sameBank, type BevicredMeta, type BevicredRow } from '@/lib/imports/bevicred-production'
import { fetchBevicredProduction } from '@/lib/bevicred.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import {
  CONTRACT_LAYOUTS, MAX_CONTRACT_LINES, matchTable, matchTableByCode, normalize, parseContractSheet,
  type ContractLine, type HeaderIssue, type LineIssue,
} from '@/lib/imports/contract-layout'
import { todaySP } from '@/lib/dates'

type Ctx = Awaited<ReturnType<typeof requireAppContext>>

export type PreviewLine = {
  line: number; cpf: string; name: string; table: string; term: number | null; amount: string | null
  ade: string; stage: string | null; seller: string
  // 'choose': a PDF or webservice line waiting for the owner to pick its table. 'skip': a webservice line left out.
  status: 'ok' | 'exists' | 'error' | 'choose' | 'skip'; messages: string[]
  // PDF and webservice layouts: the tables that fit the line (agreement, product, type, term) and what was picked.
  tableOptions?: { id: string; name: string }[]; tableId?: string; sellerId?: string
  // Webservice layout: the credential the line came from, the partner's table and the partner's seller.
  origin?: string; hint?: string; partner?: string
}
export type ImportResult = {
  error?: string
  fileIssues: string[]; ignored: string[]; tooMany: boolean
  lines: PreviewLine[]
  // PDF layouts: the report's product line and the team, for the seller of each line.
  product?: string; sellers?: { id: string; name: string }[]
  // Webservice layout: what the search said besides the lines (a credential that failed, the period).
  api?: boolean; notices?: string[]
  done?: { created: number; existed: number; failed: number; updated?: number }
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

// What the line brings to the client record, in words.
const clientParts = (l: ContractLine) => [
  Object.keys(l.client.profile).length ? 'dados pessoais' : '', l.client.address ? 'endereço' : '',
  l.client.account ? 'conta bancária' : '', l.client.registration ? 'matrícula' : '',
].filter(Boolean)

const todayBr = () => todaySP()

type Resolved = {
  line: ContractLine
  versionId?: string; tableName?: string; typeId?: string; sellerId?: string | null; stageId?: string; clientId?: string; agreementId?: string | null
  status: PreviewLine['status']; messages: string[]
  tableOptions?: { id: string; name: string }[]
  meta?: BevicredMeta
  // Webservice layout: the table or seller the owner picked (remembered at import) and the line left out on purpose.
  learnTable?: string; learnSeller?: string; skip?: boolean
  // Contract already in Corban that the report moves: its pipeline case and the stage it goes to.
  move?: { caseId: string; stageId: string; from: string; to: string }
  existingId?: string
}

// Contracts already in Corban: where the report moves each one (or why not), in words on the line.
async function planMoves(ctx: Ctx, resolved: Resolved[], stageByState: Map<string, string>) {
  const say = (r: Resolved, text: string) => { const i = r.messages.indexOf('Já cadastrado no Corban'); if (i >= 0) r.messages[i] = text }
  const ids = [...new Set(resolved.filter(r => r.status === 'exists' && r.existingId).map(r => r.existingId!))]
  if (!ids.length) return
  const { data: cases } = await ctx.supabase.from('operational_cases').select('id,proposal_id,canonical_state').in('proposal_id', ids)
  const caseOf = new Map(((cases ?? []) as { id: string; proposal_id: string; canonical_state: string }[]).map(c => [c.proposal_id, c]))
  for (const r of resolved) {
    if (r.status !== 'exists') continue
    const c = r.existingId ? caseOf.get(r.existingId) : undefined
    const target = r.line.stage
    if (!c || !target) { say(r, 'Já cadastrado no Corban (contrato não alterado)'); continue }
    const verdict = reportMove(c.canonical_state, target)
    const from = STAGE_LABEL[c.canonical_state] ?? c.canonical_state, to = STAGE_LABEL[target] ?? target
    const stageId = stageByState.get(target)
    if (verdict === 'move' && stageId) {
      r.move = { caseId: c.id, stageId, from: c.canonical_state, to: target }
      say(r, `Já cadastrado: vai mudar de ${from} para ${to}`)
    } else if (verdict === 'paid_conflict') {
      say(r, `Já cadastrado e Paga no Corban, mas ${to} no relatório: confira (não será alterado)`)
    } else {
      say(r, verdict === 'same' ? `Já cadastrado, já está ${from} (não muda)` : `Já cadastrado, está ${from} (não muda)`)
    }
  }
}

// Reads the file and checks every line against the company's catalog. Nothing is written here.
async function resolve(ctx: Ctx, formData: FormData): Promise<{ result: ImportResult; resolved: Resolved[] }> {
  const { supabase, organization } = ctx
  const empty: ImportResult = { fileIssues: [], ignored: [], tooMany: false, lines: [] }
  const layout = CONTRACT_LAYOUTS.find(l => l.key === String(formData.get('layout') ?? ''))
  const file = formData.get('file')
  if (!layout) return { result: { ...empty, error: 'Escolha o layout.' }, resolved: [] }
  if (!layout.api && (!(file instanceof File) || file.size === 0)) return { result: { ...empty, error: layout.pdf ? 'Escolha o relatório em PDF.' : 'Escolha a planilha (.xlsx ou .csv).' }, resolved: [] }

  let rows: string[][]
  let product: ValorProduct | null = null
  let meta: BevicredMeta[] = []
  const notices: string[] = []
  if (layout.api) {
    const days = [7, 15, 30].includes(Number(formData.get('days'))) ? Number(formData.get('days')) : 7
    const got = await fetchBevicredProduction(organization.id, days)
    if (!got.credentials) return { result: { ...empty, api: true, error: 'Cadastre a credencial da Bevicred em Configuração > Bevicred.' }, resolved: [] }
    notices.push(...got.errors)
    const sheet = bevicredSheet(got.rows.map(r => ({ credential: r.credential, row: r.row as BevicredRow })))
    if (sheet.meta.length === 0) return { result: { ...empty, api: true, notices, error: `A Bevicred não trouxe contratos nos últimos ${days} dias.` }, resolved: [] }
    rows = sheet.rows; meta = sheet.meta
  } else if (!(file instanceof File)) {
    return { result: empty, resolved: [] }
  } else if (layout.pdf) {
    if (!/\.pdf$/i.test(file.name)) return { result: { ...empty, error: 'Este layout lê o relatório do banco em PDF.' }, resolved: [] }
    const items = await extractPdfItems(new Uint8Array(await file.arrayBuffer()))
    if ('error' in items) return { result: { ...empty, error: PDF_ERRORS[items.error] ?? PDF_ERRORS.pdf_unreadable }, resolved: [] }
    const sheet = valorPdfSheet(items.pages)
    if ('error' in sheet) return { result: { ...empty, error: sheet.error }, resolved: [] }
    rows = sheet.rows; product = sheet.product
  } else {
    const isCsv = /\.csv$/i.test(file.name)
    if (!isCsv && !/\.xlsx$/i.test(file.name)) return { result: { ...empty, error: 'A planilha precisa ser .xlsx (Excel) ou .csv.' }, resolved: [] }
    try {
      const bytes = Buffer.from(await file.arrayBuffer())
      rows = isCsv ? csvRows(bytes, MAX_CONTRACT_LINES + 2) : await xlsxRows(bytes, MAX_CONTRACT_LINES + 2)
    } catch { return { result: { ...empty, error: 'Não consegui ler a planilha. Salve como .xlsx ou .csv e tente de novo.' }, resolved: [] } }
  }
  const today = todayBr()
  const sheet = parseContractSheet(rows, today, layout)
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
    layout.api || layout.provider ? supabase.from('organization_banks').select('id,name,tech_key').eq('is_active', true) : supabase.from('organization_banks').select('id,name,tech_key').eq('name', layout.bankName),
    supabase.from('clients').select('id,cpf').in('cpf', cpfs).is('deleted_at', null),
  ])
  type Bank = { id: string; name: string; tech_key: string | null }
  const bankList = (banks ?? []) as Bank[]
  const bank = bankList[0]
  if (!bank) return { result: { ...result, error: layout.api || layout.provider ? 'A empresa não tem bancos cadastrados.' : `O banco ${layout.bankName} não está cadastrado.` }, resolved: [] }
  const bankById = new Map(bankList.map(b => [b.id, b]))
  const keyOfBank = (b: Bank) => (b.tech_key ?? b.name).toLowerCase()

  type CatRow = { version_id: string; table_name: string; bank_id: string; provider_name: string | null; contract_type_id: string | null }
  const tables = new Map<string, { versionId: string; name: string; types: string[]; bankId: string }>()
  for (const r of (catalog ?? []) as CatRow[]) {
    if (layout.api ? !bankById.has(r.bank_id) : layout.provider ? !bankById.has(r.bank_id) || normalize(r.provider_name ?? '') !== normalize(layout.provider) : r.bank_id !== bank.id) continue
    const t = tables.get(r.version_id) ?? { versionId: r.version_id, name: r.table_name, types: [], bankId: r.bank_id }
    if (r.contract_type_id && !t.types.includes(r.contract_type_id)) t.types.push(r.contract_type_id)
    tables.set(r.version_id, t)
  }
  const tableList = [...tables.values()]
  // Agreement of each table (its route), for the client's registration (matrícula).
  const { data: versionRows } = tableList.length
    ? await supabase.from('product_table_versions').select('id,product_table_id').in('id', tableList.map(t => t.versionId))
    : { data: [] }
  const tableIds = [...new Set(((versionRows ?? []) as { product_table_id: string }[]).map(v => v.product_table_id))]
  const { data: tableRows } = tableIds.length ? await supabase.from('product_tables').select('id,route_id').in('id', tableIds) : { data: [] }
  const routeIds = [...new Set(((tableRows ?? []) as { route_id: string }[]).map(t => t.route_id))]
  const { data: routeRows } = routeIds.length ? await supabase.from('organization_product_routes').select('id,org_agreement_id').in('id', routeIds) : { data: [] }
  const agreementOfRoute = new Map(((routeRows ?? []) as { id: string; org_agreement_id: string | null }[]).map(r => [r.id, r.org_agreement_id]))
  const routeOfTable = new Map(((tableRows ?? []) as { id: string; route_id: string }[]).map(t => [t.id, t.route_id]))
  const agreementOfVersion = new Map(((versionRows ?? []) as { id: string; product_table_id: string }[])
    .map(v => [v.id, agreementOfRoute.get(routeOfTable.get(v.product_table_id) ?? '') ?? null]))
  // PDF layouts pick the table among those of the report's agreement.
  const agreementIds = [...new Set([...agreementOfVersion.values()].filter((a): a is string => !!a))]
  const { data: agreementRows } = layout.pdf && agreementIds.length
    ? await supabase.from('organization_agreements').select('id,name').in('id', agreementIds)
    : { data: [] }
  const agreementName = new Map(((agreementRows ?? []) as { id: string; name: string }[]).map(a => [a.id, a.name]))
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
    ? await supabase.from('proposal_external_identities').select('external_proposal_number,institution_key,proposal_id').in('external_proposal_number', ades)
    : { data: [] }
  const bankKey = keyOfBank(bank)
  const bankKeys = new Set(bankList.map(keyOfBank))
  const knownRows = ((known ?? []) as { external_proposal_number: string; institution_key: string; proposal_id: string }[])
    .filter(k => layout.api || layout.provider ? bankKeys.has(k.institution_key.toLowerCase()) : k.institution_key.toLowerCase() === bankKey)
  const knownAde = new Set(knownRows.map(k => k.external_proposal_number))
  // Promoter layout: the ADE counts as known only in the line's own bank.
  const knownIn = (ade: string, inBanks: Bank[]) => knownRows.find(k => k.external_proposal_number === ade && inBanks.some(b => keyOfBank(b) === k.institution_key.toLowerCase()))
  // The 2tech legacy base holds contracts whose seller payout was already made outside Corban (owner, 27/10/2026): a
  // file line with one of those numbers is left out, so its commission is never calculated again.
  const legacyAde = new Set<string>()
  if (!layout.api && ades.length) {
    const [{ data: byAde }, { data: byNumber }] = await Promise.all([
      supabase.from('legacy_contracts').select('ade').in('ade', ades),
      supabase.from('legacy_contracts').select('contract_number').in('contract_number', ades),
    ])
    for (const l of (byAde ?? []) as { ade: string | null }[]) if (l.ade) legacyAde.add(l.ade)
    for (const l of (byNumber ?? []) as { contract_number: string | null }[]) if (l.contract_number) legacyAde.add(l.contract_number)
  }
  const proposalByAde = new Map(knownRows.map(k => [k.external_proposal_number, k.proposal_id]))
  // Without ADE: the same client, table, term and amount already registered counts as the same contract.
  const clientIds = [...clientByCpf.values()]
  const { data: existing } = clientIds.length
    ? await supabase.from('proposals_v2').select('id,customer_id,product_table_version_id,term,released_amount,requested_amount,status').in('customer_id', clientIds)
    : { data: [] }
  // Amounts compared as exact decimal text ("1500.00"), never as floats.
  const exact = (v: string | number | null) => { const m = v === null ? null : parseMoneyInput(String(v)); return m === 'invalid' ? null : m }
  const sameKey = (c: string, v: string, term: number | null, rel: string | null, req: string | null) => `${c}|${v}|${term}|${rel ?? ''}|${req ?? ''}`
  const existingRows = ((existing ?? []) as { id: string; customer_id: string; product_table_version_id: string; term: number | null; released_amount: string | number | null; requested_amount: string | number | null; status: string }[])
    .filter(p => p.status !== 'cancelled')
  const proposalByKey = new Map(existingRows.map(p => [sameKey(p.customer_id, p.product_table_version_id, p.term, exact(p.released_amount), exact(p.requested_amount)), p.id]))
  const existingKeys = new Set(proposalByKey.keys())

  type Cond = { product_table_version_id: string; contract_type_id: string; term_min: number; term_max: number }
  const condRows = (conds ?? []) as Cond[]
  const termFits = (versionId: string, typeId: string, term: number) => {
    const ls = condRows.filter(c => c.product_table_version_id === versionId && c.contract_type_id === typeId)
    return !ls.length || ls.some(c => term >= c.term_min && term <= c.term_max)
  }
  const sellerList = ((sellers ?? []) as { id: string; name: string }[]).sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'))
  // Webservice layout: the company's table of each version and what the owner taught before (Bevicred table -> table,
  // partner code -> seller). Read by the server for this company only.
  const productTableOf = new Map(((versionRows ?? []) as { id: string; product_table_id: string }[]).map(v => [v.id, v.product_table_id]))
  const links = { table: new Map<string, string>(), seller: new Map<string, string>() }
  if (layout.api) {
    const { data: linkRows } = await createAdminClient().from('bevicred_links').select('kind,external_key,target_id').eq('organization_id', organization.id)
    for (const l of (linkRows ?? []) as { kind: 'table' | 'seller'; external_key: string; target_id: string }[]) links[l.kind]?.set(l.external_key, l.target_id)
  }

  const seenInFile = new Set<string>()
  const resolved: Resolved[] = sheet.lines.map(line => {
    const messages = line.issues.map(i => LINE_MESSAGE[i])
    const r: Resolved = { line, status: 'ok', messages }
    if (line.cpf && !clientByCpf.has(line.cpf) && line.name.trim().length < 3) messages.push('Cliente novo sem Nome')
    let mustChoose = false
    if (layout.api) {
      const m = meta[line.line - 2]
      r.meta = m
      const instBanks = bankList.filter(b => sameBank(m.institution, b.name))
      // Already in Corban: the same ADE in the line's bank (any bank when the bank is not registered).
      const hit = line.ade ? knownRows.find(k => k.external_proposal_number === line.ade
        && (!instBanks.length || instBanks.some(b => keyOfBank(b) === k.institution_key.toLowerCase()))) : undefined
      if (hit) r.existingId = hit.proposal_id
      // Webservice picks are keyed by ADE: a new contract between the search and the import shifts the line numbers.
      const picked = String(formData.get(`table:${line.ade}`) ?? '')
      if (!hit && (line.stage === 'cancelled' || line.stage === 'rejected')) {
        r.skip = true; r.messages = [`${m.status} na Bevicred e não está no Corban: não será cadastrado`]
      } else if (!hit && picked === 'skip') {
        r.skip = true; r.messages = ['Você escolheu não importar esta linha']
      } else if (!hit) {
        if (!instBanks.length) messages.push(`Banco "${m.institution || 'sem nome'}" não está cadastrado no Corban`)
        else {
          const typeId = line.typeKey ? typeByKey.get(line.typeKey) : undefined
          const bankTables = tableList.filter(t => instBanks.some(b => b.id === t.bankId))
          const linked = m.operationKey ? links.table.get(m.operationKey) : undefined
          const byLink = linked ? bankTables.find(t => productTableOf.get(t.versionId) === linked) : undefined
          const byName = !byLink && m.tableName ? matchTable(m.tableName, bankTables) : 'none'
          let t = byLink ?? (typeof byName === 'object' ? byName : undefined)
          const options = bankTables.filter(o => (!line.typeKey || (!!typeId && o.types.includes(typeId)))
            && (!line.term || !typeId || termFits(o.versionId, typeId, line.term)))
          if (t && !options.includes(t)) options.push(t)
          options.sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'))
          r.tableOptions = options.map(o => ({ id: o.versionId, name: o.name }))
          if (picked) {
            const o = options.find(x => x.versionId === picked)
            if (o) t = o; else messages.push('A tabela escolhida não serve para este contrato')
          }
          if (t && t !== byLink && m.operationKey) r.learnTable = productTableOf.get(t.versionId)
          if (!t) {
            if (!options.length) messages.push(`Nenhuma tabela do ${instBanks[0].name} serve para este contrato (tipo e prazo ${line.term ?? '—'}): importe a tabela da Bevicred "${m.operation || m.tableName}"`)
            else mustChoose = true
          } else {
            r.versionId = t.versionId; r.tableName = t.name; r.agreementId = agreementOfVersion.get(t.versionId) ?? null
            if (typeId) { if (t.types.includes(typeId)) r.typeId = typeId; else messages.push('Tipo de contrato não existe nessa tabela') }
            else if (t.types.length === 1) r.typeId = t.types[0]
            else messages.push('Informe o Tipo (a tabela tem mais de um tipo de contrato)')
          }
        }
      }
      const linkedSeller = m.partnerCode ? links.seller.get(m.partnerCode) : undefined
      const seller = String(formData.get(`seller:${line.ade}`) ?? '')
      if (seller) {
        if (!sellerList.some(s => s.id === seller)) messages.push('Vendedor não encontrado na equipe')
        else { r.sellerId = seller; if (m.partnerCode && seller !== linkedSeller) r.learnSeller = seller }
      } else if (linkedSeller && sellerList.some(s => s.id === linkedSeller)) r.sellerId = linkedSeller
      if (r.skip) { r.status = 'skip'; return r }
    } else if (layout.pdf && product) {
      // A contract already in Corban (same ADE) needs no table; the others list the tables that fit and wait for the pick.
      if (!(line.ade && knownAde.has(line.ade))) {
        const typeId = line.typeKey ? typeByKey.get(line.typeKey) : undefined
        const options = tableList.filter(t => agreementName.get(agreementOfVersion.get(t.versionId) ?? '') === product!.agreement
          && normalize(t.name).startsWith(product!.tablePrefix)
          && (!line.typeKey || (!!typeId && t.types.includes(typeId)))
          && (!line.term || !typeId || termFits(t.versionId, typeId, line.term)))
          .sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'))
        r.tableOptions = options.map(t => ({ id: t.versionId, name: t.name }))
        const picked = String(formData.get(`table:${line.line}`) ?? '') || (options.length === 1 ? options[0].versionId : '')
        const t = options.find(o => o.versionId === picked)
        if (!options.length) messages.push(`Nenhuma tabela de ${product.agreement} serve para este contrato (tipo e prazo ${line.term ?? '—'})`)
        else if (!t) mustChoose = true
        else {
          r.versionId = t.versionId; r.tableName = t.name; r.agreementId = agreementOfVersion.get(t.versionId) ?? null
          if (typeId) r.typeId = typeId
          else if (t.types.length === 1) r.typeId = t.types[0]
          else messages.push('Informe o Tipo (a tabela tem mais de um tipo de contrato)')
        }
      }
      const seller = String(formData.get(`seller:${line.line}`) ?? '')
      if (seller) { if (sellerList.some(s => s.id === seller)) r.sellerId = seller; else messages.push('Vendedor não encontrado na equipe') }
    } else if (layout.provider && !line.lineBank) {
      messages.push('Linha sem Banco')
    } else if (layout.provider && !bankList.some(b => sameBank(line.lineBank, b.name))) {
      messages.push(`Banco "${line.lineBank}" não está cadastrado no Corban`)
    } else if (line.table) {
      // A promoter layout matches only the line's bank tables of that promoter, by name and then by the table code.
      const lineBanks = layout.provider ? bankList.filter(b => sameBank(line.lineBank, b.name)) : [bank]
      const pool = layout.provider ? tableList.filter(t => lineBanks.some(b => b.id === t.bankId)) : tableList
      let t = matchTable(line.table, pool)
      if (layout.provider && t === 'none') t = matchTableByCode(line.table, pool)
      const where = layout.provider ? `${lineBanks[0].name} (${layout.provider})` : bank.name
      if (layout.provider && line.ade) { const hit = knownIn(line.ade, lineBanks); if (hit) r.existingId = hit.proposal_id }
      if (t === 'none') messages.push(`Tabela "${line.table}" não encontrada no ${where}`)
      else if (t === 'ambiguous') messages.push(`Tabela "${line.table}" bate com mais de uma tabela do ${where}`)
      else {
        r.versionId = t.versionId; r.tableName = t.name; r.agreementId = agreementOfVersion.get(t.versionId) ?? null
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
    const known = layout.provider ? !!r.existingId : !!line.ade && knownAde.has(line.ade)
    if (!known && line.ade && legacyAde.has(line.ade)) {
      r.status = 'skip'; r.messages = ['Já pago na base antiga (2tech): não será cadastrado']; return r
    }
    if (messages.length) { r.status = 'error'; return r }
    if (mustChoose) { r.status = 'choose'; messages.push('Escolha a tabela'); return r }
    const fileKey = line.ade ? `ade:${line.ade}` : `k:${line.cpf}|${r.versionId}|${line.term}|${line.released ?? ''}|${line.requested ?? ''}`
    if (seenInFile.has(fileKey)) { r.status = 'error'; messages.push('Linha repetida na planilha'); return r }
    seenInFile.add(fileKey)
    if ((layout.api || layout.provider ? !!r.existingId : line.ade && knownAde.has(line.ade)) || (!line.ade && r.clientId && existingKeys.has(sameKey(r.clientId, r.versionId!, line.term, line.released, line.requested)))) {
      r.status = 'exists'
      r.existingId = (layout.api || layout.provider) && r.existingId ? r.existingId : line.ade ? proposalByAde.get(line.ade) : proposalByKey.get(sameKey(r.clientId!, r.versionId!, line.term, line.released, line.requested))
      messages.push('Já cadastrado no Corban')
    } else if (!r.sellerId) messages.push(NO_SELLER)
    const parts = clientParts(line)
    if (parts.length) messages.push(`Ficha do cliente: ${parts.join(', ')} (só preenche o que estiver vazio)`)
    messages.push(...line.warnings)
    return r
  })
  await planMoves(ctx, resolved, stageByState)
  if (layout.pdf && product) { result.product = product.label; result.sellers = sellerList }
  if (layout.api) { result.api = true; result.sellers = sellerList; result.notices = notices }
  result.lines = resolved.map(({ line: l, tableName, status, messages, tableOptions, versionId, sellerId, meta: m }) => ({
    line: l.line, cpf: l.cpf, name: l.name, table: tableName ?? l.table, term: l.term, amount: l.released ?? l.requested,
    // An unknown stage shows the sheet's own text (it used to read "Automática", the label for no stage at all).
    ade: l.ade, stage: l.stage ? STAGE_LABEL[l.stage] ?? l.stage : l.stageRaw || null, seller: l.seller, status, messages,
    ...(tableOptions ? { tableOptions, tableId: versionId } : {}), ...(layout.pdf || layout.api ? { sellerId: sellerId ?? undefined } : {}),
    ...(m ? { origin: m.credential, hint: m.operation || m.tableName, partner: m.partnerName || m.partnerCode } : {}),
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
  // A webservice line with an error cannot be fixed in a file: it is left out and the others are imported.
  const api = !!result.api
  if (!api && resolved.some(r => r.status === 'error')) return { ...result, error: 'Corrija as linhas com erro antes de importar.' }
  if (resolved.some(r => r.status === 'choose')) return { ...result, error: 'Escolha a tabela de cada contrato antes de importar.' }
  const { supabase, organization } = ctx
  const done: { created: number; existed: number; failed: number; updated?: number } = { created: 0, existed: 0, failed: 0, updated: 0 }
  const learned: { kind: 'table' | 'seller'; external_key: string; external_label: string; target_id: string }[] = []
  for (const [i, r] of resolved.entries()) {
    const out = result.lines[i]
    const l = r.line
    if (r.status === 'error' || r.status === 'skip') { if (r.status === 'error') out.messages = ['Não importado', ...out.messages]; continue }
    // What the owner picked for this line is remembered for the next searches (only for a line that was written).
    const learn = () => {
      const m = r.meta
      if (!m) return
      if (r.learnTable && m.operationKey) learned.push({ kind: 'table', external_key: m.operationKey.slice(0, 200), external_label: (m.operation || m.tableName).slice(0, 200), target_id: r.learnTable })
      if (r.learnSeller && m.partnerCode) learned.push({ kind: 'seller', external_key: m.partnerCode.slice(0, 200), external_label: (m.partnerName ? `${m.partnerName} (${m.partnerCode})` : m.partnerCode).slice(0, 200), target_id: r.learnSeller })
    }
    // A contract already in Corban is not changed; its client record still gets the empty fields filled.
    const enrich = async (clientId: string) => {
      const { filled, warnings } = await enrichClient(supabase, organization.id, clientId, l.client, r.agreementId ?? null)
      return [...(filled.length ? [`Ficha do cliente completada: ${filled.join(', ')}`] : []), ...warnings, ...l.warnings]
    }
    if (r.status === 'exists') {
      done.existed++
      learn()
      const head = out.messages.find(m => m.startsWith('Já cadastrado')) ?? 'Já cadastrado no Corban (contrato não alterado)'
      let moved: string[] = []
      if (r.move) {
        // The bank's report moves the contract (owner, 20/10/2026); the pipeline history says so.
        const { error: moveError } = await supabase.rpc('move_case_to_stage', {
          p_case_id: r.move.caseId, p_stage_id: r.move.stageId, p_note: 'Pelo relatório do banco (importação de contratos)',
          p_pendency_due_at: null, p_paid_on: r.move.to === 'paid' ? l.paidOn : null,
        })
        if (moveError) moved = [`Já cadastrado, mas a etapa não mudou (${rpcMessage(moveError.message)})`]
        else { done.updated = (done.updated ?? 0) + 1; moved = [`Atualizado: ${STAGE_LABEL[r.move.from] ?? r.move.from} → ${STAGE_LABEL[r.move.to] ?? r.move.to}`] }
      }
      out.messages = [...(moved.length ? moved : [head]), ...(r.clientId ? await enrich(r.clientId) : [])]
      continue
    }
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
    if (row.duplicate) { done.existed++; out.status = 'exists'; out.messages = ['Já cadastrado no Corban (contrato não alterado)', ...(await enrich(clientId))]; continue }
    done.created++
    learn()
    // "Associar proposta": the associated seller replaced the spreadsheet's (owner decision, 08/10/2026).
    const { data: link } = await supabase.from('proposal_seller_links').select('matched_by').eq('proposal_id', row.proposal_id).maybeSingle()
    const tail = [...(link ? [`Vendedor da proposta associada (achada pelo ${link.matched_by === 'ade' ? 'nº' : 'CPF'})`] : r.sellerId ? [] : [NO_SELLER]), ...(await enrich(clientId))]
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
  if (learned.length) {
    const seen = new Set<string>()
    const rows = learned.filter(x => { const k = `${x.kind}|${x.external_key}`; if (seen.has(k)) return false; seen.add(k); return true })
      .map(x => ({ ...x, organization_id: organization.id, updated_by: ctx.user.id, updated_at: new Date().toISOString() }))
    const { error: learnError } = await createAdminClient().from('bevicred_links').upsert(rows, { onConflict: 'organization_id,kind,external_key' })
    if (learnError) result.notices = [...(result.notices ?? []), 'As escolhas de tabela e vendedor não foram guardadas para a próxima busca.']
  }
  revalidatePath('/app/propostas')
  return { ...result, done }
}
