'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { stageLegacyChunk } from './actions'
import { guessLegacyMapping, LEGACY_FIELDS } from '@/lib/legacy/fields'
import { readLegacyFileInBrowser, type LegacySheet } from '@/lib/legacy/browser-read'
import { feedbackUrl } from '@/lib/feedback'

const label = 'text-[13px] font-medium text-ink-soft'
const BLOCK = 500

// The browser reads the file (any size) and shows its columns; then only the chosen columns go to the server, in blocks
// of 500 lines, into one draft batch whose preview opens at the end. Nothing is written until the preview is confirmed.
export function LegacyImportClient() {
  const router = useRouter()
  const [file, setFile] = useState<File | null>(null)
  const [source, setSource] = useState('2tech')
  const [sheet, setSheet] = useState<LegacySheet | null>(null)
  const [cols, setCols] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState('')

  async function readColumns() {
    if (!file) { setError('Escolha o arquivo.'); return }
    setBusy(true); setError(''); setSheet(null); setProgress('Lendo o arquivo...')
    try {
      const r = await readLegacyFileInBrowser(file)
      if ('error' in r) { setError(r.error); return }
      setSheet(r)
      setCols(Object.fromEntries(Object.entries(guessLegacyMapping(r.headers)).filter(([, v]) => v)) as Record<string, string>)
    } catch {
      setError('Não foi possível ler o arquivo.')
    } finally { setBusy(false); setProgress('') }
  }

  async function send() {
    if (!sheet || !file) return
    setBusy(true); setError('')
    try {
      const chosen = [...new Set(Object.values(cols).filter(Boolean))]
      const index = chosen.map(h => sheet.headers.indexOf(h))
      const mapping = Object.fromEntries(LEGACY_FIELDS.map(f => [f.key, cols[f.key] ?? '']).filter(([, v]) => v))
      let batch: string | null = null
      for (let i = 0; i < sheet.body.length; i += BLOCK) {
        setProgress(`Enviando linhas ${i + 1} a ${Math.min(i + BLOCK, sheet.body.length)} de ${sheet.body.length}...`)
        const rows = sheet.body.slice(i, i + BLOCK).map(r => index.map(j => r[j] ?? ''))
        const r = await stageLegacyChunk({ batch, source, fileName: file.name, sha: sheet.sha, headers: chosen, headerRow: sheet.headerRow, offset: i, rows, mapping })
        if (!r.ok) { setError(r.error); return }
        batch = r.batch
      }
      if (!batch) { setError('O arquivo não tem linhas.'); return }
      router.push(feedbackUrl(`/app/configuracao/base-antiga/${batch}`, 'ok:legado_em_conferencia'))
    } catch {
      setError('A conexão caiu no meio do envio. As linhas já enviadas ficaram em conferência: descarte essa importação e envie de novo.')
    } finally { setBusy(false); setProgress('') }
  }

  return (
    <div className="grid gap-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <label className={label}>Sistema de origem
          <input value={source} onChange={e => setSource(e.target.value)} maxLength={30} className="field mt-1.5" />
        </label>
        <label className={label}>Arquivo exportado (XLSX, XLS ou CSV)
          <input type="file" accept=".xlsx,.xls,.csv,.txt" onChange={e => { setFile(e.target.files?.[0] ?? null); setSheet(null); setError('') }} className="field mt-1.5" />
        </label>
      </div>
      <div className="flex justify-end">
        <button type="button" onClick={readColumns} disabled={busy || !file} className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted disabled:opacity-50">Ler colunas do arquivo</button>
      </div>

      {sheet && (
        <div className="grid gap-4 border-t border-line pt-5">
          <p className="text-sm text-ink">{sheet.body.filter(r => r.some(c => c !== "")).length} linha(s) após os títulos. Diga qual coluna é qual; as que o sistema reconheceu já vêm marcadas.</p>
          <div className="grid gap-4 sm:grid-cols-3">
            {LEGACY_FIELDS.map(f => (
              <label key={f.key} className={label}>{f.label}{f.required && ' *'}
                <select value={cols[f.key] ?? ''} onChange={e => setCols(c => ({ ...c, [f.key]: e.target.value }))} className="field mt-1.5">
                  <option value="">{f.required ? 'Escolha a coluna' : 'Não tem'}</option>
                  {sheet.headers.filter(Boolean).map(h => <option key={h} value={h}>{h}</option>)}
                </select>
              </label>
            ))}
          </div>
          <div className="flex justify-end">
            <button type="button" onClick={send} disabled={busy || !cols.cpf} className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">{busy ? 'Enviando...' : 'Enviar para conferência'}</button>
          </div>
        </div>
      )}

      {progress && <p role="status" className="text-sm text-ink-soft">{progress}</p>}
      {error && <div role="alert" className="rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">{error}</div>}
    </div>
  )
}
