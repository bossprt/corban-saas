'use server'

import { createHash } from 'crypto'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'
import { parseMoneyInput } from '@/lib/money-input'
import { buildReceiptRows, readReceiptFile, RECEIPT_ISSUE_LABEL, splitHeader, type ReceiptKind, type ReceiptMapping } from '@/lib/receipts/parse'

const KINDS: ReceiptKind[] = ['upfront', 'deferred', 'chargeback']
const FILE_ERROR: Record<string, string> = {
  empty_file: 'O arquivo está vazio.', file_too_large: 'Arquivo acima de 10 MB.', unsupported_file: 'Formato não aceito. Envie XLSX, XLS ou CSV.',
  xlsx_unreadable: 'Não foi possível ler a planilha.', no_header: 'Não encontrei a linha de títulos das colunas.',
}

type Source = { kind: 'bank' | 'provider'; id: string }
const parseSource = (v: FormDataEntryValue | null): Source | null => {
  const [kind, id] = String(v ?? '').split(':')
  return (kind === 'bank' || kind === 'provider') && isUuid(id) ? { kind, id } : null
}

async function readUpload(formData: FormData) {
  const file = formData.get('file')
  if (!(file instanceof File) || file.size === 0) return { error: FILE_ERROR.empty_file } as const
  const bytes = new Uint8Array(await file.arrayBuffer())
  const read = await readReceiptFile(bytes, file.name)
  if (read.error) return { error: FILE_ERROR[read.error] ?? 'Não foi possível ler o arquivo.' } as const
  const sheet = splitHeader(read.rows)
  if (!sheet) return { error: FILE_ERROR.no_header } as const
  return { file, sheet, sha: createHash('sha256').update(bytes).digest('hex') } as const
}

export type InspectResult =
  | { ok: false; error: string }
  | { ok: true; headers: string[]; sample: string[][]; rowCount: number; mapping: Partial<ReceiptMapping> | null }

// Step 1: reads the file and returns its columns and the saved layout for this source and kind. Nothing is stored.
export async function inspectReceiptFile(formData: FormData): Promise<InspectResult> {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.edit')) return { ok: false, error: 'Seu perfil não pode importar relatórios.' }
  const source = parseSource(formData.get('source'))
  const kind = String(formData.get('kind') ?? '') as ReceiptKind
  if (!source || !KINDS.includes(kind)) return { ok: false, error: 'Escolha a fonte pagadora e o tipo do relatório.' }
  const up = await readUpload(formData)
  if ('error' in up) return { ok: false, error: up.error! }
  const { data: layout } = await supabase.from('receipt_layouts').select('mapping')
    .eq('organization_id', organization.id).eq('source_kind', source.kind).eq('source_id', source.id).eq('report_kind', kind).maybeSingle()
  const mapping = (layout?.mapping ?? null) as Partial<ReceiptMapping> | null
  const known = mapping && Object.values(mapping).every(h => !h || up.sheet.headers.includes(h)) ? mapping : null
  return { ok: true, headers: up.sheet.headers, sample: up.sheet.body.filter(r => r.some(c => String(c).trim())).slice(0, 5), rowCount: up.sheet.body.length, mapping: known }
}

export type ImportResult = { ok: false; error: string; issues?: { row: number; message: string }[] }

// Step 2: applies the chosen columns, saves them as the layout of the source and kind, and imports a draft report.
export async function importReceiptFile(formData: FormData): Promise<ImportResult> {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.edit')) return { ok: false, error: 'Seu perfil não pode importar relatórios.' }
  const source = parseSource(formData.get('source'))
  const kind = String(formData.get('kind') ?? '') as ReceiptKind
  const month = String(formData.get('month') ?? '')
  if (!source || !KINDS.includes(kind) || !/^\d{4}-\d{2}$/.test(month)) return { ok: false, error: 'Preencha fonte pagadora, tipo e mês de referência.' }
  const declared = parseMoneyInput(formData.get('declared_total'))
  if (declared === 'invalid') return { ok: false, error: 'Total do relatório inválido. Use o formato 1.234,56.' }
  const col = (k: string) => String(formData.get(`col_${k}`) ?? '').trim() || undefined
  const mapping: ReceiptMapping = { ade: col('ade') ?? '', amount: col('amount') ?? '', installment: col('installment'), paid_on: col('paid_on'), bank: col('bank') }
  if (!mapping.ade || !mapping.amount) return { ok: false, error: 'Indique a coluna do contrato (ADE) e a do valor.' }

  const up = await readUpload(formData)
  if ('error' in up) return { ok: false, error: up.error! }
  if (Object.values(mapping).some(h => h && !up.sheet.headers.includes(h))) return { ok: false, error: 'Uma coluna escolhida não existe neste arquivo.' }
  const built = buildReceiptRows(up.sheet, mapping, kind)
  if (built.issues.length) {
    return { ok: false, error: `${built.issues.length} linha(s) com problema. Corrija o arquivo e envie de novo.`, issues: built.issues.slice(0, 50).map(i => ({ row: i.row, message: RECEIPT_ISSUE_LABEL[i.code] })) }
  }
  if (!built.rows.length) return { ok: false, error: 'Nenhuma linha com contrato e valor foi encontrada.' }

  const saved = await supabase.rpc('save_receipt_layout', { p_org: organization.id, p_source_kind: source.kind, p_source_id: source.id, p_report_kind: kind, p_mapping: mapping })
  if (saved.error) return { ok: false, error: 'Não foi possível salvar o modelo de colunas.' }
  const { data: reportId, error } = await supabase.rpc('import_receipt_report', {
    p_org: organization.id, p_source_kind: source.kind, p_source_id: source.id, p_report_kind: kind, p_reference_month: `${month}-01`,
    p_file_name: up.file.name.slice(0, 160), p_file_sha256: up.sha, p_declared_total: declared, p_rows: built.rows,
  })
  if (error) {
    if (/receipt_file_already_imported/.test(error.message ?? '')) return { ok: false, error: 'Este arquivo já foi importado.' }
    return { ok: false, error: 'Não foi possível importar o relatório.' }
  }
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
