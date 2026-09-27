'use client'

import { useState } from 'react'
import { inspectLegacyFile, stageLegacyFile, type LegacyInspect } from './actions'
import { LEGACY_FIELDS } from '@/lib/legacy/fields'

const label = 'text-[13px] font-medium text-ink-soft'

// Two steps on the same file: read the columns (nothing stored), then send every row to the preview.
export function LegacyImportClient() {
  const [file, setFile] = useState<File | null>(null)
  const [source, setSource] = useState('2tech')
  const [inspect, setInspect] = useState<Extract<LegacyInspect, { ok: true }> | null>(null)
  const [cols, setCols] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function readColumns() {
    if (!file) { setError('Escolha o arquivo.'); return }
    setBusy(true); setError(''); setInspect(null)
    try {
      const fd = new FormData(); fd.set('file', file)
      const r = await inspectLegacyFile(fd)
      if (!r.ok) { setError(r.error); return }
      setInspect(r)
      setCols(Object.fromEntries(Object.entries(r.mapping).filter(([, v]) => v)) as Record<string, string>)
    } finally { setBusy(false) }
  }

  async function send() {
    setBusy(true); setError('')
    try {
      const fd = new FormData(); fd.set('file', file!); fd.set('source', source)
      for (const f of LEGACY_FIELDS) fd.set(`col_${f.key}`, cols[f.key] ?? '')
      const r = await stageLegacyFile(fd)
      // On success the action opens the preview; only failures come back here.
      if (r && !r.ok) setError(r.error)
    } finally { setBusy(false) }
  }

  return (
    <div className="grid gap-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <label className={label}>Sistema de origem
          <input value={source} onChange={e => setSource(e.target.value)} maxLength={30} className="field mt-1.5" />
        </label>
        <label className={label}>Arquivo exportado (XLSX, XLS ou CSV)
          <input type="file" accept=".xlsx,.xls,.csv,.txt" onChange={e => { setFile(e.target.files?.[0] ?? null); setInspect(null) }} className="field mt-1.5" />
        </label>
      </div>
      <div className="flex justify-end">
        <button type="button" onClick={readColumns} disabled={busy || !file} className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted disabled:opacity-50">Ler colunas do arquivo</button>
      </div>

      {inspect && (
        <div className="grid gap-4 border-t border-line pt-5">
          <p className="text-sm text-ink">{inspect.rowCount} linha(s) após os títulos. Diga qual coluna é qual; as que o sistema reconheceu já vêm marcadas.</p>
          <div className="grid gap-4 sm:grid-cols-3">
            {LEGACY_FIELDS.map(f => (
              <label key={f.key} className={label}>{f.label}{f.required && ' *'}
                <select value={cols[f.key] ?? ''} onChange={e => setCols(c => ({ ...c, [f.key]: e.target.value }))} className="field mt-1.5">
                  <option value="">{f.required ? 'Escolha a coluna' : 'Não tem'}</option>
                  {inspect.headers.filter(Boolean).map(h => <option key={h} value={h}>{h}</option>)}
                </select>
              </label>
            ))}
          </div>
          <div className="overflow-x-auto rounded-[10px] border border-line">
            <table className="w-full text-left text-[12px]">
              <thead className="bg-surface-muted text-muted"><tr>{inspect.headers.map((h, i) => <th key={i} className="whitespace-nowrap px-3 py-2 font-medium">{h}</th>)}</tr></thead>
              <tbody>{inspect.sample.map((r, i) => <tr key={i} className="border-t border-line">{inspect.headers.map((_, j) => <td key={j} className="whitespace-nowrap px-3 py-1.5 text-ink-soft">{r[j]}</td>)}</tr>)}</tbody>
            </table>
          </div>
          <div className="flex justify-end">
            <button type="button" onClick={send} disabled={busy || !cols.cpf} className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">{busy ? 'Lendo as linhas...' : 'Enviar para conferência'}</button>
          </div>
        </div>
      )}

      {error && <div role="alert" className="rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">{error}</div>}
    </div>
  )
}
