'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { Upload } from 'lucide-react'
import { readLegacyFileInBrowser, type LegacySheet } from '@/lib/legacy/browser-read'
import { chunk } from '@/lib/crm'
import { importDndChunk } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'
const PART = 5000
const MAX_ROWS = 200_000
const PHONE_HINT = /tel|fone|cel|whats|n[uú]mero/i

type Done = { added: number; already: number; invalid: number }

// A "Não perturbe" list (the banks send them): read in the browser; only the phone column(s) chosen here are sent.
export function DndImport() {
  const router = useRouter()
  const [file, setFile] = useState<File | null>(null)
  const [sheet, setSheet] = useState<LegacySheet | null>(null)
  const [cols, setCols] = useState<number[]>([])
  const [error, setError] = useState<string | null>(null)
  const [progress, setProgress] = useState<{ sent: number; total: number } | null>(null)
  const [done, setDone] = useState<Done | null>(null)

  async function pick(f: File | null) {
    setError(null); setDone(null); setSheet(null); setFile(f); setCols([])
    if (!f) return
    const r = await readLegacyFileInBrowser(f)
    if ('error' in r) { setError(r.error); return }
    const body = r.body.filter(row => row.some(c => c !== ''))
    if (body.length > MAX_ROWS) { setError(`O arquivo tem ${body.length} linhas. O limite é ${MAX_ROWS.toLocaleString('pt-BR')} por importação: divida o arquivo.`); return }
    setSheet({ ...r, body })
    setCols(r.headers.map((h, i) => (PHONE_HINT.test(h) ? i : -1)).filter(i => i >= 0))
  }

  const phones = sheet ? sheet.body.flatMap(row => cols.map(i => String(row[i] ?? '').trim()).filter(Boolean)) : []

  async function send() {
    if (!sheet || !file || !phones.length) return
    setError(null)
    const parts = chunk(phones, PART)
    const total: Done = { added: 0, already: 0, invalid: 0 }
    setProgress({ sent: 0, total: phones.length })
    for (const [n, part] of parts.entries()) {
      const r = await importDndChunk({ fileName: file.name, phones: part })
      if (!r.ok) { setError(`${r.message} ${n > 0 ? `Os primeiros ${(n * PART).toLocaleString('pt-BR')} números entraram; enviar de novo não duplica.` : ''}`); setProgress(null); return }
      total.added += r.added; total.already += r.already; total.invalid += r.invalid
      setProgress({ sent: Math.min(phones.length, (n + 1) * PART), total: phones.length })
    }
    setProgress(null); setDone(total); setSheet(null); setFile(null); setCols([])
    router.refresh()
  }

  return (
    <div className="grid gap-3 px-5 pb-5 pt-3">
      <label className={label}>Arquivo (Excel ou CSV)
        <input type="file" accept=".xlsx,.xls,.csv,.txt" onChange={e => pick(e.target.files?.[0] ?? null)} className="field mt-1.5" />
      </label>
      {sheet && (
        <fieldset className="grid gap-2">
          <legend className={label}>Qual coluna tem o telefone? (pode marcar mais de uma)</legend>
          <div className="flex flex-wrap gap-x-4 gap-y-2">
            {sheet.headers.map((h, i) => (
              <label key={i} className="inline-flex items-center gap-1.5 text-sm text-ink">
                <input type="checkbox" checked={cols.includes(i)} onChange={() => setCols(c => (c.includes(i) ? c.filter(x => x !== i) : [...c, i]))} className="accent-[var(--brand)]" />
                {h || `Coluna ${i + 1}`}
              </label>
            ))}
          </div>
          <p className="text-xs text-muted">{phones.length.toLocaleString('pt-BR')} número(s) para enviar. Só os números vão para o sistema; as outras colunas ficam no seu computador.</p>
          <button type="button" onClick={send} disabled={!phones.length || !!progress} className="inline-flex h-10 w-fit items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">
            <Upload size={16} aria-hidden />{progress ? `Enviando ${progress.sent.toLocaleString('pt-BR')} de ${progress.total.toLocaleString('pt-BR')}...` : 'Importar lista'}
          </button>
        </fieldset>
      )}
      {error && <p role="alert" className="rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-2.5 text-sm text-[#991B1B]">{error}</p>}
      {done && (
        <p role="status" className="rounded-[10px] border border-[#BBE5C8] bg-[#E3F5E9] px-4 py-2.5 text-sm text-[#15803D]">
          Lista importada: {done.added.toLocaleString('pt-BR')} novo(s), {done.already.toLocaleString('pt-BR')} já estava(m) na lista, {done.invalid.toLocaleString('pt-BR')} inválido(s).
        </p>
      )}
    </div>
  )
}
