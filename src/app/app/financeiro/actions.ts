'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { bankAccountOf } from '@/lib/finBankAccounts'
import { isUuid } from '@/lib/team'
import { parseMoneyInput } from '@/lib/money-input'
import { buildReceiptRows, RECEIPT_ISSUE_LABEL, type ReceiptKind, type ReceiptMapping } from '@/lib/receipts/parse'

const KINDS: ReceiptKind[] = ['upfront', 'deferred', 'chargeback']
const MAX_ROWS = 20_000

type Source = { kind: 'bank' | 'provider'; id: string }
const parseSource = (v: unknown): Source | null => {
  const [kind, id] = String(v ?? '').split(':')
  return (kind === 'bank' || kind === 'provider') && isUuid(id) ? { kind, id } : null
}
const isText = (v: unknown, max: number) => typeof v === 'string' && v.length <= max

export type InspectResult = { ok: false; error: string } | { ok: true; mapping: Partial<ReceiptMapping> | null }

// Step 1: the browser read the file (any size); only its column titles come here, to find the saved layout of this
// source and kind. Nothing is stored.
export async function inspectReceiptFile(input: { source: string; kind: string; headers: string[] }): Promise<InspectResult> {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.edit')) return { ok: false, error: 'Seu perfil não pode importar relatórios.' }
  const source = parseSource(input?.source)
  const kind = String(input?.kind ?? '') as ReceiptKind
  if (!source || !KINDS.includes(kind)) return { ok: false, error: 'Escolha a fonte pagadora e o tipo do relatório.' }
  const headers = Array.isArray(input?.headers) ? input.headers.filter(h => isText(h, 200)) : []
  const { data: layout } = await supabase.from('receipt_layouts').select('mapping')
    .eq('organization_id', organization.id).eq('source_kind', source.kind).eq('source_id', source.id).eq('report_kind', kind).maybeSingle()
  const mapping = (layout?.mapping ?? null) as Partial<ReceiptMapping> | null
  return { ok: true, mapping: mapping && Object.values(mapping).every(h => !h || headers.includes(h)) ? mapping : null }
}

export type ImportResult = { ok: false; error: string; issues?: { row: number; message: string }[] }
export type ReceiptImportInput = {
  source: string; kind: string; month: string; declaredTotal: string; fileName: string; sha: string; bankAccount?: string
  mapping: ReceiptMapping; headerRow: number; headers: string[]; body: string[][]
}

// Step 2: only the chosen columns of the file arrive (read in the browser). They are validated here again, saved as
// the layout of the source and kind, and imported as a draft report.
export async function importReceiptFile(input: ReceiptImportInput): Promise<ImportResult> {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.edit')) return { ok: false, error: 'Seu perfil não pode importar relatórios.' }
  const source = parseSource(input?.source)
  const kind = String(input?.kind ?? '') as ReceiptKind
  const month = String(input?.month ?? '')
  if (!source || !KINDS.includes(kind) || !/^\d{4}-\d{2}$/.test(month)) return { ok: false, error: 'Preencha fonte pagadora, tipo e mês de referência.' }
  const declared = parseMoneyInput(input.declaredTotal ?? '')
  if (declared === 'invalid') return { ok: false, error: 'Total do relatório inválido. Use o formato 1.234,56.' }
  const m = input.mapping ?? ({} as ReceiptMapping)
  const opt = (v: unknown) => (isText(v, 200) && String(v).trim() ? String(v).trim() : undefined)
  const mapping: ReceiptMapping = { ade: opt(m.ade) ?? '', amount: opt(m.amount) ?? '', installment: opt(m.installment), paid_on: opt(m.paid_on), bank: opt(m.bank) }
  if (!mapping.ade || !mapping.amount) return { ok: false, error: 'Indique a coluna do contrato (ADE) e a do valor.' }
  const { headers, body, headerRow } = input
  const shapeOk = Array.isArray(headers) && headers.length <= 5 && headers.every(h => isText(h, 200))
    && Array.isArray(body) && body.every(r => Array.isArray(r) && r.length <= headers.length && r.every(c => isText(c, 300)))
    && Number.isInteger(headerRow) && headerRow >= 1 && headerRow <= 30
    && /^[0-9a-f]{64}$/.test(String(input.sha ?? '')) && isText(input.fileName, 1000)
  if (!shapeOk) return { ok: false, error: 'Não foi possível ler o arquivo.' }
  if (body.length > MAX_ROWS) return { ok: false, error: `Arquivo com mais de ${MAX_ROWS.toLocaleString('pt-BR')} linhas. Divida o relatório.` }
  if (Object.values(mapping).some(h => h && !headers.includes(h))) return { ok: false, error: 'Uma coluna escolhida não existe neste arquivo.' }
  const built = buildReceiptRows({ headers, body, headerRow }, mapping, kind)
  if (built.issues.length) {
    return { ok: false, error: `${built.issues.length} linha(s) com problema. Corrija o arquivo e envie de novo.`, issues: built.issues.slice(0, 50).map(i => ({ row: i.row, message: RECEIPT_ISSUE_LABEL[i.code] })) }
  }
  if (!built.rows.length) return { ok: false, error: 'Nenhuma linha com contrato e valor foi encontrada.' }

  const saved = await supabase.rpc('save_receipt_layout', { p_org: organization.id, p_source_kind: source.kind, p_source_id: source.id, p_report_kind: kind, p_mapping: mapping })
  if (saved.error) return { ok: false, error: 'Não foi possível salvar o modelo de colunas.' }
  const { data: reportId, error } = await supabase.rpc('import_receipt_report', {
    p_org: organization.id, p_source_kind: source.kind, p_source_id: source.id, p_report_kind: kind, p_reference_month: `${month}-01`,
    p_file_name: input.fileName.slice(0, 160), p_file_sha256: input.sha, p_declared_total: declared, p_rows: built.rows,
  })
  if (error) {
    if (/receipt_file_already_imported/.test(error.message ?? '')) return { ok: false, error: 'Este arquivo já foi importado.' }
    return { ok: false, error: 'Não foi possível importar o relatório.' }
  }
  // The account that received the money: its receipts are posted there (07/10/2026).
  const bank = bankAccountOf(input.bankAccount)
  if (bank) await supabase.rpc('set_receipt_report_bank_account', { p_report: reportId, p_bank_account: bank })
  revalidatePath('/app/financeiro')
  redirect(feedbackUrl(`/app/financeiro/relatorios/${reportId}`, 'ok:relatorio_importado'))
}

const reportBack = (id: string, code: FeedbackCode): never => redirect(feedbackUrl(`/app/financeiro/relatorios/${id}`, code))
const receiptError = (m: string): FeedbackCode | null =>
  /receipt_report_has_unresolved_lines/.test(m) ? 'erro:relatorio_pendente'
  : /receipt_total_mismatch/.test(m) ? 'erro:relatorio_total'
  : /receipt_report_is_closed/.test(m) ? 'erro:relatorio_fechado'
  : /note_required/.test(m) ? 'erro:receita_motivo'
  : null

export async function linkLine(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const report = String(formData.get('report_id') ?? ''), line = String(formData.get('line_id') ?? '')
  const ade = String(formData.get('ade') ?? '').trim()
  if (!isUuid(report) || !isUuid(line) || !ade) return reportBack(report, 'erro:requisicao_invalida')
  // The operator types the ADE of the right proposal; it is looked up in this company only.
  const { data: found } = await supabase.from('proposals_v2').select('id').eq('organization_id', organization.id).eq('external_proposal_id', ade).limit(2)
  if (!found || found.length !== 1) return reportBack(report, 'erro:proposta_ade_nao_encontrada')
  const { error } = await supabase.rpc('link_receipt_line', { p_line_id: line, p_proposal_id: found[0].id })
  if (error) return reportBack(report, receiptError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(`/app/financeiro/relatorios/${report}`)
  return reportBack(report, 'ok:linha_vinculada')
}

export async function ignoreLine(formData: FormData) {
  const { supabase } = await requireAppContext()
  const report = String(formData.get('report_id') ?? ''), line = String(formData.get('line_id') ?? '')
  if (!isUuid(report) || !isUuid(line)) return reportBack(report, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('ignore_receipt_line', { p_line_id: line, p_note: String(formData.get('note') ?? '') })
  if (error) return reportBack(report, receiptError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath(`/app/financeiro/relatorios/${report}`)
  return reportBack(report, 'ok:linha_ignorada')
}

export async function reportAction(formData: FormData) {
  const { supabase } = await requireAppContext()
  const report = String(formData.get('report_id') ?? '')
  const op = String(formData.get('op') ?? '')
  if (!isUuid(report) || !['rematch', 'confirm', 'discard'].includes(op)) return reportBack(report, 'erro:requisicao_invalida')
  const rpc = op === 'rematch' ? 'rematch_receipt_report' : op === 'confirm' ? 'confirm_receipt_report' : 'discard_receipt_report'
  const { error } = await supabase.rpc(rpc, { p_report_id: report })
  if (error) return reportBack(report, receiptError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath('/app/financeiro')
  revalidatePath(`/app/financeiro/relatorios/${report}`)
  return reportBack(report, op === 'rematch' ? 'ok:comparacao_refeita' : op === 'confirm' ? 'ok:relatorio_confirmado' : 'ok:relatorio_descartado')
}

export async function acceptDivergence(formData: FormData) {
  const { supabase } = await requireAppContext()
  const receipt = String(formData.get('receipt_id') ?? '')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl('/app/financeiro/conciliacao', code))
  if (!isUuid(receipt)) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('accept_receipt_divergence', { p_receipt_id: receipt, p_note: String(formData.get('note') ?? '') })
  if (error) return back(receiptError(error.message ?? '') ?? classifyDbFeedback(error))
  revalidatePath('/app/financeiro/conciliacao')
  return back('ok:divergencia_aceita')
}
