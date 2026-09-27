'use server'

import { createHash } from 'crypto'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'
import { readReceiptFile, splitHeader } from '@/lib/receipts/parse'
import { buildLegacyRows, guessLegacyMapping, LEGACY_FIELDS, type LegacyMapping } from '@/lib/legacy/parse'

const PATH = '/app/configuracao/base-antiga'
const BLOCK = 1000
const FILE_ERROR: Record<string, string> = {
  empty_file: 'O arquivo está vazio.', file_too_large: 'Arquivo acima de 10 MB.', unsupported_file: 'Formato não aceito. Envie XLSX, XLS ou CSV.',
  xlsx_unreadable: 'Não foi possível ler a planilha.', no_header: 'Não encontrei a linha de títulos das colunas.',
}
const back = (code: FeedbackCode, path = PATH): never => { revalidatePath(PATH); return redirect(feedbackUrl(path, code)) }
const legacyError = (e: { message?: string; code?: string }): FeedbackCode => {
  const m = String(e.message ?? '')
  if (m.includes('legacy_cutoff_required')) return 'erro:legado_corte'
  if (m.includes('legacy_file_already_imported')) return 'erro:legado_arquivo_repetido'
  if (m.includes('legacy_batch_empty')) return 'erro:legado_lote_vazio'
  if (m.includes('reason_required')) return 'erro:legado_motivo'
  if (m.includes('invalid_cutoff')) return 'erro:legado_corte_invalido'
  return classifyDbFeedback(e)
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

export async function saveLegacyCutoff(formData: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (membership.role !== 'admin') return back('erro:sem_permissao')
  const cutoff = String(formData.get('cutoff_on') ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(cutoff)) return back('erro:legado_corte_invalido')
  const { error } = await supabase.rpc('set_legacy_settings', { p_org: membership.organization_id, p_cutoff_on: cutoff, p_opportunities: false })
  return back(error ? legacyError(error) : 'ok:legado_corte')
}

export type LegacyInspect = { ok: false; error: string } | { ok: true; headers: string[]; sample: string[][]; rowCount: number; mapping: LegacyMapping }

// Step 1: reads the file and pre-selects the columns. Nothing is stored.
export async function inspectLegacyFile(formData: FormData): Promise<LegacyInspect> {
  const { membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return { ok: false, error: 'Seu perfil não importa a base antiga.' }
  const up = await readUpload(formData)
  if ('error' in up) return { ok: false, error: up.error! }
  return { ok: true, headers: up.sheet.headers, sample: up.sheet.body.filter(r => r.some(c => String(c).trim())).slice(0, 5), rowCount: up.sheet.body.length, mapping: guessLegacyMapping(up.sheet.headers) }
}

// Step 2: stages every row (in blocks) into a draft batch and opens its preview.
export async function stageLegacyFile(formData: FormData): Promise<{ ok: false; error: string }> {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return { ok: false, error: 'Seu perfil não importa a base antiga.' }
  const source = String(formData.get('source') ?? '').trim().toLowerCase()
  if (!/^[a-z0-9_-]{2,30}$/.test(source)) return { ok: false, error: 'Informe o sistema de origem (ex.: 2tech).' }
  const mapping: LegacyMapping = {}
  for (const f of LEGACY_FIELDS) { const v = String(formData.get(`col_${f.key}`) ?? '').trim(); if (v) mapping[f.key] = v }
  if (!mapping.cpf) return { ok: false, error: 'Indique a coluna do CPF.' }
  const up = await readUpload(formData)
  if ('error' in up) return { ok: false, error: up.error! }
  if (Object.values(mapping).some(h => h && !up.sheet.headers.includes(h))) return { ok: false, error: 'Uma coluna escolhida não existe neste arquivo.' }
  const rows = buildLegacyRows(up.sheet, mapping)
  if (!rows.length) return { ok: false, error: 'O arquivo não tem linhas.' }

  let batch: string | null = null
  for (let i = 0; i < rows.length; i += BLOCK) {
    const { data, error } = await supabase.rpc('stage_legacy_rows', {
      p_org: membership.organization_id, p_batch: batch, p_source: source, p_file_name: up.file.name.slice(0, 200), p_file_sha256: up.sha, p_rows: rows.slice(i, i + BLOCK),
    })
    if (error) {
      const m = String(error.message ?? '')
      if (m.includes('legacy_cutoff_required')) return { ok: false, error: 'Defina antes a data de corte.' }
      if (m.includes('legacy_file_already_imported')) return { ok: false, error: 'Este arquivo já foi importado (ou está em conferência).' }
      return { ok: false, error: 'Não foi possível ler as linhas do arquivo.' }
    }
    batch = data as string
  }
  revalidatePath(PATH)
  redirect(feedbackUrl(`${PATH}/${batch}`, 'ok:legado_em_conferencia'))
}

const batchId = (f: FormData) => { const id = String(f.get('batch_id') ?? ''); return isUuid(id) ? id : null }

export async function confirmLegacyBatch(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = batchId(formData); if (!id) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('confirm_legacy_batch', { p_batch: id })
  return back(error ? legacyError(error) : 'ok:legado_confirmado', `${PATH}/${id}`)
}

export async function undoLegacyBatch(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = batchId(formData); if (!id) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('undo_legacy_batch', { p_batch: id, p_reason: String(formData.get('reason') ?? '') })
  return back(error ? legacyError(error) : 'ok:legado_desfeito', `${PATH}/${id}`)
}

export async function discardLegacyBatch(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = batchId(formData); if (!id) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('discard_legacy_batch', { p_batch: id })
  return back(error ? legacyError(error) : 'ok:legado_descartado')
}
