'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createHash, randomUUID } from 'crypto'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { classifyDbFeedback, FEEDBACK, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'
import { parseMoneyInput } from '@/lib/money-input'
import type { OfxLine } from '@/lib/finance/ofx'
import { checkUpload, safeFileName } from '@/lib/documents'

const BASE = '/app/financeiro/empresa'
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const uuidOrNull = (f: FormData, k: string) => { const v = text(f, k); return isUuid(v) ? v : null }
const dateOrNull = (f: FormData, k: string) => { const v = text(f, k); return /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null }
const back = (path: string, code: FeedbackCode): never => { revalidatePath(BASE, 'layout'); return redirect(feedbackUrl(path, code)) }
const safePath = (f: FormData) => { const p = text(f, 'return_to'); return p.startsWith(BASE) && !p.includes('//') ? p : BASE }
const finError = (e: { message?: string; code?: string }): FeedbackCode => {
  const m = String(e.message ?? '')
  for (const [k, c] of [
    ['fin_account_invalid', 'erro:fin_conta_contabil'], ['fin_branch_invalid', 'erro:fin_filial'], ['fin_bank_account_invalid', 'erro:fin_conta_bancaria'],
    ['invalid_amount', 'erro:fin_valor'], ['fin_installments_invalid', 'erro:fin_parcelas'], ['fin_due_required', 'erro:fin_vencimento'],
    ['fin_settle_invalid', 'erro:fin_baixa'], ['fin_settle_amount', 'erro:fin_valor_pago'], ['fin_partial_automatic', 'erro:fin_parcial_automatico'], ['fin_remainder_settled', 'erro:fin_restante_baixado'], ['fin_entry_not_open', 'erro:fin_nao_aberto'], ['fin_entry_not_settled', 'erro:fin_nao_baixado'],
    ['fin_entry_automatic', 'erro:fin_automatico'], ['fin_entry_reconciled', 'erro:fin_conciliado'], ['reason_required', 'erro:fin_motivo'],
    ['fin_account_code_exists', 'erro:fin_codigo_repetido'], ['fin_account_in_use', 'erro:fin_conta_em_uso'], ['fin_account_open_entries', 'erro:fin_conta_com_abertos'], ['fin_account_system', 'erro:fin_conta_sistema'],
    ['fin_match_amount', 'erro:fin_valor_diferente'], ['fin_match_other_account', 'erro:fin_outra_conta'], ['fin_line_not_pending', 'erro:fin_linha_tratada'],
    ['fin_already_posted', 'erro:fin_ja_lancado'], ['fin_line_not_matched', 'erro:fin_linha_tratada'], ['fin_line_not_ignored', 'erro:fin_linha_tratada'], ['fin_statement_already_imported', 'erro:fin_extrato_repetido'],
  ] as const) if (m.includes(k)) return c
  return classifyDbFeedback(e)
}
async function editor() {
  const ctx = await requireAppContext()
  return can(ctx.access, 'financeiro.edit') ? ctx : null
}

const intervalDays = (f: FormData): number | null => {
  const v = text(f, 'interval')
  if (v === '15' || v === '7') return Number(v)
  if (v === 'days') { const n = Number.parseInt(text(f, 'interval_days'), 10); return Number.isInteger(n) && n >= 1 && n <= 365 ? n : -1 }
  return null
}

// New entry (06/11/2026): on a refusal the form stays open with what was typed and the reason; only success redirects.
export type NewEntryState = { message: string | null; values: Record<string, string>; nonce: number }
export async function createEntry(prev: NewEntryState, f: FormData): Promise<NewEntryState> {
  const values = Object.fromEntries([...f.entries()].filter(([, v]) => typeof v === 'string').map(([k, v]) => [k, String(v)]))
  const fail = (code: FeedbackCode | string): NewEntryState => ({ message: code in FEEDBACK ? FEEDBACK[code as FeedbackCode] : code, values, nonce: prev.nonce + 1 })
  const ctx = await editor(); if (!ctx) return fail('erro:sem_permissao')
  const amount = parseMoneyInput(f.get('amount'))
  if (amount === null || amount === 'invalid') return fail('erro:fin_valor')
  if (amount === '0.00') return fail('O valor precisa ser maior que zero.')
  const settled = f.get('settled') === 'on'
  const { error } = await ctx.supabase.rpc('fin_create_entry', {
    p_org: ctx.organization.id, p_direction: text(f, 'direction') === 'in' ? 'in' : 'out', p_description: text(f, 'description'),
    p_account: uuidOrNull(f, 'account_id'), p_branch: uuidOrNull(f, 'branch_id'), p_counterpart: text(f, 'counterpart'), p_document: text(f, 'document'),
    p_amount: amount, p_due_on: dateOrNull(f, 'due_on'), p_competence_on: dateOrNull(f, 'competence_on'),
    // "Uma vez" is one entry; "Repetir" the same amount every month; "Parcelar" the amount divided (06/10/2026).
    p_installments: text(f, 'plan') === 'once' ? 1 : Number.parseInt(text(f, 'installments') || '1', 10) || 1,
    p_repeat: text(f, 'plan') === 'repeat',
    // Days between installments (06/10/2026): empty = one month apart.
    p_interval_days: intervalDays(f),
    p_settled_on: settled ? dateOrNull(f, 'due_on') : null, p_bank_account: settled ? uuidOrNull(f, 'bank_account_id') : null,
  })
  if (error) return fail(finError(error))
  return back(safePath(f), 'ok:fin_lancado')
}

// Settle with paid value, interest, discount and an optional receipt (04/11/2026). Paid below the amount leaves the rest
// open (the database decides and records it). The receipt goes to private storage after the settlement.
export async function settleEntry(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(safePath(f), 'erro:sem_permissao')
  const paid = parseMoneyInput(f.get('paid')), interest = parseMoneyInput(f.get('interest')), discount = parseMoneyInput(f.get('discount'))
  if (paid === 'invalid' || interest === 'invalid' || discount === 'invalid') return back(safePath(f), 'erro:fin_valor')
  const file = f.get('receipt')
  const receipt = file instanceof File && file.size > 0 ? file : null
  if (receipt) { const c = checkUpload(receipt.size, receipt.type, new Uint8Array(await receipt.arrayBuffer())); if (!c.ok) return back(safePath(f), c.code) }
  const entryId = uuidOrNull(f, 'entry_id')
  const { data: rest, error } = await ctx.supabase.rpc('fin_settle_entry', {
    p_entry: entryId, p_settled_on: dateOrNull(f, 'settled_on'), p_bank_account: uuidOrNull(f, 'bank_account_id'),
    p_paid: paid, p_interest: interest ?? '0', p_discount: discount ?? '0',
  })
  if (error) return back(safePath(f), finError(error))
  if (receipt && entryId && !(await storeReceipt(ctx, entryId, receipt))) return back(safePath(f), 'erro:fin_comprovante_depois')
  return back(safePath(f), rest ? 'ok:fin_baixa_parcial_feita' : 'ok:fin_baixado')
}

// Attach a receipt later (from the "⋯" menu).
export async function addReceipt(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(safePath(f), 'erro:sem_permissao')
  const file = f.get('receipt'); const entryId = uuidOrNull(f, 'entry_id')
  if (!(file instanceof File) || file.size === 0 || !entryId) return back(safePath(f), 'erro:doc_vazio')
  const c = checkUpload(file.size, file.type, new Uint8Array(await file.arrayBuffer())); if (!c.ok) return back(safePath(f), c.code)
  return back(safePath(f), (await storeReceipt(ctx, entryId, file)) ? 'ok:fin_comprovante' : 'erro:doc_armazenamento')
}

// Path <org>/<entry>/<uuid>/<file>; the storage policy and fin_add_receipt check the folder belongs to the entry. A file
// left without a record (rare DB failure) stays private to the company, never a false record.
async function storeReceipt(ctx: NonNullable<Awaited<ReturnType<typeof editor>>>, entryId: string, file: File): Promise<boolean> {
  const bytes = Buffer.from(await file.arrayBuffer())
  const check = checkUpload(file.size, file.type, bytes)
  if (!check.ok) return false
  const name = safeFileName(file.name)
  const path = `${ctx.organization.id}/${entryId}/${randomUUID()}/${name}`
  const { error: up } = await ctx.supabase.storage.from('fin-receipts').upload(path, bytes, { contentType: check.mime, upsert: false })
  if (up) return false
  const { error } = await ctx.supabase.rpc('fin_add_receipt', {
    p_entry: entryId, p_path: path, p_file_name: name, p_mime: check.mime, p_size: bytes.length, p_sha256: createHash('sha256').update(bytes).digest('hex'),
  })
  return !error
}

// Edit an open entry (owner request 04/11/2026): the database keeps the before/after of each field in the history;
// the reason is asked here so every change says why.
export async function updateEntry(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(safePath(f), 'erro:sem_permissao')
  const amount = parseMoneyInput(f.get('amount'))
  if (amount === null || amount === 'invalid') return back(safePath(f), 'erro:fin_valor')
  if (text(f, 'reason').length < 3) return back(safePath(f), 'erro:fin_motivo')
  const { error } = await ctx.supabase.rpc('fin_update_entry', {
    p_entry: uuidOrNull(f, 'entry_id'), p_description: text(f, 'description'), p_account: uuidOrNull(f, 'account_id'), p_branch: uuidOrNull(f, 'branch_id'),
    p_counterpart: text(f, 'counterpart'), p_document: text(f, 'document'), p_amount: amount, p_due_on: dateOrNull(f, 'due_on'),
    p_competence_on: dateOrNull(f, 'competence_on'), p_reason: text(f, 'reason'),
  })
  return back(safePath(f), error ? finError(error) : 'ok:fin_alterado')
}

// Pay or receive the entries ticked in the list, one settlement each (same rules as the single one).
export async function settleMany(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(safePath(f), 'erro:sem_permissao')
  const ids = [...new Set(f.getAll('entry_ids').map(String).filter(isUuid))].slice(0, 300)
  if (!ids.length) return back(safePath(f), 'erro:fin_nada_marcado')
  let failed = 0
  for (const id of ids) {
    const { error } = await ctx.supabase.rpc('fin_settle_entry', { p_entry: id, p_settled_on: dateOrNull(f, 'settled_on'), p_bank_account: uuidOrNull(f, 'bank_account_id') })
    if (error) failed++
  }
  return back(safePath(f), failed ? 'erro:fin_baixa_parcial' : 'ok:fin_varios_baixados')
}

export async function undoSettlement(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(safePath(f), 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_undo_settlement', { p_entry: uuidOrNull(f, 'entry_id'), p_reason: text(f, 'reason') })
  return back(safePath(f), error ? finError(error) : 'ok:fin_baixa_desfeita')
}

export async function cancelEntry(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(safePath(f), 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_cancel_entry', { p_entry: uuidOrNull(f, 'entry_id'), p_reason: text(f, 'reason') })
  return back(safePath(f), error ? finError(error) : 'ok:fin_cancelado')
}

export async function saveBankAccount(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/contas`, 'erro:sem_permissao')
  const opening = parseMoneyInput(f.get('opening_balance') || '0')
  if (opening === 'invalid') return back(`${BASE}/contas`, 'erro:fin_valor')
  const { error } = await ctx.supabase.rpc('fin_save_bank_account', {
    p_org: ctx.organization.id, p_id: uuidOrNull(f, 'id'), p_bank_name: text(f, 'bank_name'), p_label: text(f, 'label'), p_agency: text(f, 'agency'),
    p_account_number: text(f, 'account_number'), p_opening_balance: opening ?? '0', p_opening_on: dateOrNull(f, 'opening_on'), p_active: f.get('is_active') !== 'false', p_reason: text(f, 'reason') || null,
  })
  return back(`${BASE}/contas`, error ? finError(error) : 'ok:fin_conta_salva')
}

export async function saveChartAccount(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/plano`, 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_save_chart_account', {
    p_org: ctx.organization.id, p_id: uuidOrNull(f, 'id'), p_code: text(f, 'code'), p_name: text(f, 'name'), p_kind: text(f, 'kind'),
    p_is_group: f.get('is_group') === 'on', p_active: f.get('is_active') !== 'false',
  })
  return back(`${BASE}/plano`, error ? finError(error) : 'ok:fin_plano_salvo')
}

export async function setAutoPost(f: FormData) {
  const ctx = await requireAppContext()
  const { error } = await ctx.supabase.rpc('fin_set_auto_post', { p_org: ctx.organization.id, p_auto: text(f, 'auto') === 'true' })
  return back(`${BASE}/a-lancar`, error ? finError(error) : 'ok:fin_modo_salvo')
}

export async function postPending(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/a-lancar`, 'erro:sem_permissao')
  const kind = text(f, 'kind')
  const { error } = await ctx.supabase.rpc('fin_post_pending', { p_org: ctx.organization.id, p_kind: kind === 'payout' ? 'payout' : 'commission_receipt', p_ref: uuidOrNull(f, 'ref') })
  return back(`${BASE}/a-lancar`, error ? finError(error) : 'ok:fin_lancado')
}

// Statement lines come already read by the browser (the OFX never travels whole).
export async function importStatement(input: { bankAccount: string; fileName: string; sha: string; lines: OfxLine[] }): Promise<{ ok: true; added: number } | { ok: false; error: string }> {
  const ctx = await editor(); if (!ctx) return { ok: false, error: 'Seu perfil não importa extratos.' }
  if (!isUuid(input?.bankAccount) || !/^[0-9a-f]{64}$/.test(String(input?.sha)) || !Array.isArray(input?.lines) || input.lines.length < 1 || input.lines.length > 5000) {
    return { ok: false, error: 'Extrato inválido.' }
  }
  const lines = input.lines.map(l => ({ fitid: String(l.fitid).slice(0, 80), posted_on: String(l.posted_on), amount: String(l.amount), memo: String(l.memo ?? '').slice(0, 200) }))
  const { data: importId, error } = await ctx.supabase.rpc('fin_import_statement', { p_bank_account: input.bankAccount, p_file_name: String(input.fileName).slice(0, 200), p_file_sha256: input.sha, p_lines: lines })
  if (error) return { ok: false, error: /fin_statement_already_imported/.test(error.message ?? '') ? 'Este extrato já foi importado.' : 'Não foi possível importar o extrato.' }
  // New lines only: a line already imported from another file is skipped by the database.
  const { data: imp } = await ctx.supabase.from('fin_statement_imports').select('line_count').eq('id', importId as string).maybeSingle()
  revalidatePath(`${BASE}/extrato`)
  return { ok: true, added: Number(imp?.line_count ?? 0) }
}

export async function matchLine(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/extrato`, 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_match_line', { p_line: uuidOrNull(f, 'line_id'), p_entry: uuidOrNull(f, 'entry_id') })
  return back(`${BASE}/extrato`, error ? finError(error) : 'ok:fin_conciliado')
}

export async function entryFromLine(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/extrato`, 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_entry_from_line', { p_line: uuidOrNull(f, 'line_id'), p_account: uuidOrNull(f, 'account_id'), p_branch: uuidOrNull(f, 'branch_id'), p_description: text(f, 'description') })
  return back(`${BASE}/extrato`, error ? finError(error) : 'ok:fin_conciliado')
}

export async function ignoreLine(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/extrato`, 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_ignore_line', { p_line: uuidOrNull(f, 'line_id') })
  return back(`${BASE}/extrato`, error ? finError(error) : 'ok:fin_linha_ignorada')
}

// Undo a reconciliation (04/11/2026): the line goes back to pending and the entry to what it was, with the reason.
export async function unmatchLine(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/extrato`, 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_unmatch_line', { p_line: uuidOrNull(f, 'line_id'), p_reason: text(f, 'reason') })
  return back(`${BASE}/extrato`, error ? finError(error) : 'ok:fin_conciliacao_desfeita')
}

export async function restoreLine(f: FormData) {
  const ctx = await editor(); if (!ctx) return back(`${BASE}/extrato`, 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('fin_restore_line', { p_line: uuidOrNull(f, 'line_id') })
  return back(`${BASE}/extrato`, error ? finError(error) : 'ok:fin_linha_voltou')
}
