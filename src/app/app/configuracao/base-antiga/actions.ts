'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'
import { buildLegacyRows, LEGACY_FIELDS, type LegacyMapping } from '@/lib/legacy/parse'

const PATH = '/app/configuracao/base-antiga'
const BLOCK = 500
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

export async function saveLegacyCutoff(formData: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (membership.role !== 'admin') return back('erro:sem_permissao')
  const cutoff = String(formData.get('cutoff_on') ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(cutoff)) return back('erro:legado_corte_invalido')
  const { error } = await supabase.rpc('set_legacy_settings', { p_org: membership.organization_id, p_cutoff_on: cutoff, p_opportunities: false })
  return back(error ? legacyError(error) : 'ok:legado_corte')
}

export type LegacyChunk = {
  batch: string | null; source: string; fileName: string; sha: string
  // Only the chosen columns travel; headerRow + offset keeps the line numbers of the original file.
  headers: string[]; headerRow: number; offset: number; rows: string[][]; mapping: LegacyMapping
}
export type LegacyChunkResult = { ok: true; batch: string } | { ok: false; error: string }

// The browser reads the file and sends it in blocks: each block is staged into the same draft batch. Nothing reaches
// clients or contracts until the batch is confirmed on the preview screen.
export async function stageLegacyChunk(c: LegacyChunk): Promise<LegacyChunkResult> {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return { ok: false, error: 'Seu perfil não importa a base antiga.' }
  const source = String(c?.source ?? '').trim().toLowerCase()
  if (!/^[a-z0-9_-]{2,30}$/.test(source)) return { ok: false, error: 'Informe o sistema de origem (ex.: 2tech).' }
  if (c.batch !== null && !isUuid(c.batch)) return { ok: false, error: 'Importação inválida. Comece de novo.' }
  if (!/^[0-9a-f]{64}$/.test(String(c.sha)) || !Array.isArray(c.headers) || c.headers.length > LEGACY_FIELDS.length || !Array.isArray(c.rows) || c.rows.length > BLOCK
      || !Number.isInteger(c.headerRow) || !Number.isInteger(c.offset) || c.offset < 0) return { ok: false, error: 'Não foi possível ler o arquivo. Comece de novo.' }
  const mapping: LegacyMapping = {}
  for (const f of LEGACY_FIELDS) { const v = String(c.mapping?.[f.key] ?? '').trim(); if (v) mapping[f.key] = v }
  if (!mapping.cpf) return { ok: false, error: 'Indique a coluna do CPF.' }
  if (Object.values(mapping).some(h => h && !c.headers.includes(h))) return { ok: false, error: 'Uma coluna escolhida não existe neste arquivo.' }
  const rows = buildLegacyRows({ headers: c.headers.map(String), body: c.rows.map(r => (Array.isArray(r) ? r : []).map(v => String(v ?? ''))), headerRow: c.headerRow + c.offset }, mapping)
  if (!rows.length) return c.batch ? { ok: true, batch: c.batch } : { ok: false, error: 'O arquivo não tem linhas.' }
  const { data, error } = await supabase.rpc('stage_legacy_rows', {
    p_org: membership.organization_id, p_batch: c.batch, p_source: source, p_file_name: String(c.fileName ?? '').slice(0, 200) || 'arquivo', p_file_sha256: c.sha, p_rows: rows,
  })
  if (error) {
    const m = String(error.message ?? '')
    if (m.includes('legacy_cutoff_required')) return { ok: false, error: 'Defina antes a data de corte.' }
    if (m.includes('legacy_file_already_imported')) return { ok: false, error: 'Este arquivo já foi importado (ou está em conferência).' }
    return { ok: false, error: 'Não foi possível ler as linhas do arquivo.' }
  }
  revalidatePath(PATH)
  return { ok: true, batch: data as string }
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
