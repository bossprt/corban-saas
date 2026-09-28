'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { FileSpreadsheet } from 'lucide-react'
import { readLegacyFileInBrowser, type LegacySheet } from '@/lib/legacy/browser-read'
import { buildCampaignRows, CAMPAIGN_FIELDS, CAMPAIGN_FIELD_LABEL, CAMPAIGN_LIMITS, chunk, guessCampaignMapping, type CampaignField, type CampaignMapping } from '@/lib/crm'
import { importCampaignChunk } from '../../actions'

type Done = { created: number; linked: number; duplicates: number; invalid: number }
const label = 'text-[13px] font-medium text-ink-soft'

// Campaign spreadsheet: read in the browser (any size), the operator confirms which column is what, the rows go in blocks.
// Nothing is shown from the rows except the first lines of the preview on this screen; the file never leaves the browser whole.
export function CampaignImport({ campaignId, alreadyImported }: { campaignId: string; alreadyImported: string[] }) {
  const router = useRouter()
  const [file, setFile] = useState<File | null>(null)
  const [sheet, setSheet] = useState<LegacySheet | null>(null)
  const [mapping, setMapping] = useState<CampaignMapping>({})
  const [error, setError] = useState<string | null>(null)
  const [progress, setProgress] = useState<{ sent: number; total: number } | null>(null)
  const [done, setDone] = useState<Done | null>(null)

  async function pick(f: File | null) {
    setError(null); setDone(null); setSheet(null); setFile(f)
    if (!f) return
    const r = await readLegacyFileInBrowser(f)
    if ('error' in r) { setError(r.error); return }
    const body = r.body.filter(row => row.some(c => c !== ''))
    if (body.length > CAMPAIGN_LIMITS.rows) { setError(`A planilha tem ${body.length} linhas. O limite é ${CAMPAIGN_LIMITS.rows.toLocaleString('pt-BR')} por importação: divida o arquivo.`); return }
    setSheet({ ...r, body })
    const guess = guessCampaignMapping(r.headers)
    const used = new Set(CAMPAIGN_FIELDS.map(k => guess[k]).filter(i => i !== undefined))
    setMapping({ ...guess, info: r.headers.map((_, i) => i).filter(i => !used.has(i) && r.headers[i]) })
  }

  const setField = (f: CampaignField, v: string) => setMapping(m => {
    const i = v === '' ? undefined : Number(v)
    return { ...m, [f]: i, info: (m.info ?? []).filter(x => x !== i) }
  })
  const toggleInfo = (i: number) => setMapping(m => ({ ...m, info: (m.info ?? []).includes(i) ? (m.info ?? []).filter(x => x !== i) : [...(m.info ?? []), i] }))

  const rows = sheet ? buildCampaignRows(sheet.headers, sheet.body, mapping) : []
  const ready = !!sheet && mapping.name !== undefined && (mapping.cpf !== undefined || mapping.phone !== undefined)
  const repeated = sheet && alreadyImported.includes(sheet.sha)

  async function send() {
    if (!sheet || !file || !ready) return
    setError(null)
    const parts = chunk(rows, CAMPAIGN_LIMITS.chunk)
    const total: Done = { created: 0, linked: 0, duplicates: 0, invalid: 0 }
    setProgress({ sent: 0, total: rows.length })
    for (const [n, part] of parts.entries()) {
      const r = await importCampaignChunk({ campaignId, fileName: file.name, sha: sheet.sha, rows: part })
      if (!r.ok) { setError(`${r.message} ${n > 0 ? `As primeiras ${(n * CAMPAIGN_LIMITS.chunk).toLocaleString('pt-BR')} linhas entraram; enviar de novo não duplica.` : ''}`); setProgress(null); return }
      total.created += r.created; total.linked += r.linked; total.duplicates += r.duplicates; total.invalid += r.invalid
      setProgress({ sent: Math.min(rows.length, (n + 1) * CAMPAIGN_LIMITS.chunk), total: rows.length })
    }
    setProgress(null); setDone(total); setSheet(null); setFile(null)
    router.refresh()
  }

  const cols = sheet?.headers ?? []
  return (
    <div className="grid gap-4">
      <label className="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-[12px] border border-dashed border-line-strong bg-surface-muted/50 px-4 py-6 text-center text-sm text-ink-soft hover:bg-surface-muted">
        <FileSpreadsheet size={22} className="text-brand" aria-hidden />
        <span><span className="font-medium text-brand">Escolher planilha</span> (XLSX, XLS ou CSV)</span>
        <span className="text-xs text-muted">{file ? file.name : 'Precisa ter pelo menos o nome e o CPF ou telefone.'}</span>
        <input type="file" accept=".xlsx,.xls,.csv,.txt" aria-label="Planilha da campanha" className="sr-only" onChange={e => pick(e.target.files?.[0] ?? null)} />
      </label>

      {error && <p role="alert" className="rounded-[10px] border border-[#F5C2C2] bg-[#FDECEC] px-4 py-2.5 text-sm text-[#991B1B]">{error}</p>}
      {done && (
        <p role="status" className="rounded-[10px] border border-[#BBE5C8] bg-[#E9F7EE] px-4 py-2.5 text-sm text-[#166534]">
          Importação concluída: {done.created} lead(s) novo(s), dos quais {done.linked} já eram clientes. {done.duplicates} já estavam na campanha e {done.invalid} linha(s) sem nome ou sem CPF/telefone ficaram de fora.
        </p>
      )}

      {sheet && (
        <div className="grid gap-4">
          {repeated && <p className="rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-2.5 text-sm text-[#92400E]">Este arquivo já foi importado nesta campanha. Pode enviar de novo: quem já está na campanha não é repetido.</p>}
          <p className="text-sm text-ink-soft">{sheet.body.length.toLocaleString('pt-BR')} linha(s) no arquivo (títulos na linha {sheet.headerRow}). Confira qual coluna é cada campo:</p>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {CAMPAIGN_FIELDS.map(f => (
              <label key={f} className={label}>{CAMPAIGN_FIELD_LABEL[f]}{(f === 'name') && ' *'}
                <select value={mapping[f] ?? ''} onChange={e => setField(f, e.target.value)} aria-label={`Coluna ${CAMPAIGN_FIELD_LABEL[f]}`} className="field mt-1.5">
                  <option value="">Não tem</option>
                  {cols.map((h, i) => <option key={i} value={i}>{h || `Coluna ${i + 1}`}</option>)}
                </select>
              </label>
            ))}
          </div>
          <fieldset>
            <legend className={`${label} mb-1.5`}>Outras colunas que o vendedor vai ver no lead (margem, banco, benefício...)</legend>
            <div className="flex flex-wrap gap-x-4 gap-y-1.5">
              {cols.map((h, i) => (CAMPAIGN_FIELDS.some(f => mapping[f] === i) || !h) ? null : (
                <label key={i} className="flex items-center gap-1.5 text-sm text-ink">
                  <input type="checkbox" checked={(mapping.info ?? []).includes(i)} onChange={() => toggleInfo(i)} className="accent-[var(--brand)]" />{h}
                </label>
              ))}
            </div>
          </fieldset>
          <div className="flex flex-wrap items-center gap-3">
            <button type="button" disabled={!ready || !!progress} onClick={send} className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-60">
              {progress ? `Enviando ${progress.sent.toLocaleString('pt-BR')} de ${progress.total.toLocaleString('pt-BR')}...` : `Importar ${rows.length.toLocaleString('pt-BR')} lead(s)`}
            </button>
            {!ready && <span className="text-xs text-[#92400E]">Escolha a coluna do nome e a do CPF ou do telefone.</span>}
          </div>
        </div>
      )}
    </div>
  )
}
