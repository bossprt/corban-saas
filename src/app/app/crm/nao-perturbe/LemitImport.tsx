'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { Upload } from 'lucide-react'
import { firstZipEntry, lemitColumns, lemitLine, parseDdds, type LemitRow } from '@/lib/imports/lemit-list'
import { finishLemitImport, importLemitChunk } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'
const PART = 5000
const n = (v: number) => v.toLocaleString('pt-BR')

// Lemit "Não Perturbe SP" list (owner, 24/10/2026): the file (.zip as it comes, or .csv) is read here as a stream; only
// the phones of the chosen area codes (and their validity date) are sent, in parts. Nothing else leaves the computer.
export function LemitImport() {
  const router = useRouter()
  const [file, setFile] = useState<File | null>(null)
  const [ddds, setDdds] = useState('68')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState<{ read: number; kept: number; pct: number } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<{ total: number; validNow: number; removed: number } | null>(null)

  async function textStream(f: File): Promise<{ stream: ReadableStream<string>; size: number } | string> {
    if (/\.zip$/i.test(f.name)) {
      const entry = await firstZipEntry(f)
      if (!entry) return 'Não consegui abrir o .zip. Descompacte e envie o .csv.'
      const raw = f.slice(entry.dataStart, entry.dataStart + entry.compressedSize).stream()
      const bytes = entry.method === 0 ? raw : entry.method === 8 ? raw.pipeThrough(new DecompressionStream('deflate-raw')) : null
      if (!bytes) return 'Este .zip usa uma compressão que o navegador não abre. Descompacte e envie o .csv.'
      return { stream: bytes.pipeThrough(new TextDecoderStream()), size: entry.uncompressedSize || f.size * 5 }
    }
    return { stream: f.stream().pipeThrough(new TextDecoderStream()), size: f.size }
  }

  async function run() {
    if (!file) return
    const chosen = new Set(parseDdds(ddds))
    if (!chosen.size) { setError('Informe pelo menos um DDD (ex.: 68).'); return }
    setBusy(true); setError(null); setDone(null); setProgress({ read: 0, kept: 0, pct: 0 })
    try {
      const opened = await textStream(file)
      if (typeof opened === 'string') { setError(opened); return }
      const batch = crypto.randomUUID()
      const reader = opened.stream.getReader()
      let rest = '', cols: ReturnType<typeof lemitColumns> = null, lines = 0, chars = 0, kept = 0
      let part: LemitRow[] = []
      const send = async () => {
        if (!part.length) return true
        const r = await importLemitChunk({ batch, fileName: file.name, rows: part })
        if (!r.ok) { setError(`${r.message} Nada foi trocado: a lista anterior do Lemit continua valendo.`); return false }
        kept += part.length; part = []
        return true
      }
      for (;;) {
        const { value, done: end } = await reader.read()
        const text = rest + (value ?? '')
        const pieces = text.split(/\r?\n/)
        rest = end ? '' : pieces.pop() ?? ''
        chars += value?.length ?? 0
        for (const line of pieces) {
          if (!line) continue
          if (!cols) { cols = lemitColumns(line); if (!cols) { setError('O arquivo não tem a coluna do telefone (phone).'); return } continue }
          lines++
          const row = lemitLine(line, cols, chosen)
          if (row) part.push(row)
          if (part.length >= PART && !(await send())) return
        }
        setProgress({ read: lines, kept: kept + part.length, pct: Math.min(99, Math.round((chars / opened.size) * 100)) })
        if (end) break
      }
      if (!(await send())) return
      if (!kept) { setError('Nenhum telefone desses DDDs no arquivo. Nada foi trocado.'); return }
      const r = await finishLemitImport({ batch })
      if (!r.ok) { setError(r.message); return }
      setProgress(null); setDone({ total: r.total, validNow: r.validNow, removed: r.removed }); setFile(null)
      router.refresh()
    } catch {
      setError('Não foi possível ler o arquivo. Tente de novo; se o .zip não abrir, descompacte e envie o .csv. A lista anterior continua valendo.')
    } finally { setBusy(false) }
  }

  return (
    <div className="grid gap-3 px-5 pb-5 pt-3">
      <p className="text-xs text-muted">O arquivo do Lemit (.zip ou .csv) é lido no seu computador; só os telefones dos DDDs escolhidos são enviados. Importar de novo substitui a lista anterior do Lemit; o que foi marcado à mão e as listas dos bancos continuam.</p>
      <div className="flex flex-wrap items-end gap-3">
        <label className={`${label} min-w-[240px] flex-1`}>Arquivo
          <input type="file" accept=".zip,.csv,.txt" disabled={busy} onChange={e => { setFile(e.target.files?.[0] ?? null); setDone(null); setError(null) }} className="field mt-1.5" />
        </label>
        <label className={label}>DDDs<input value={ddds} onChange={e => setDdds(e.target.value)} disabled={busy} placeholder="68" className="field mt-1.5 w-32" /></label>
        <button type="button" onClick={run} disabled={busy || !file} className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">
          <Upload size={16} aria-hidden />{busy ? 'Importando...' : 'Importar lista do Lemit'}
        </button>
      </div>
      {progress && (
        <div className="grid gap-1.5">
          <p className="text-sm text-ink-soft">Lendo o arquivo… {n(progress.read)} linhas lidas · {n(progress.kept)} telefones dos DDDs escolhidos</p>
          <div className="h-2.5 overflow-hidden rounded-full bg-[#F3F1EC]"><div className="h-2.5 rounded-full bg-brand transition-all" style={{ width: `${progress.pct}%` }} /></div>
        </div>
      )}
      {error && <p role="alert" className="rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-2.5 text-sm text-[#991B1B]">{error}</p>}
      {done && (
        <p role="status" className="rounded-[10px] border border-[#BBE5C8] bg-[#E3F5E9] px-4 py-2.5 text-sm text-[#15803D]">
          Lista do Lemit atualizada: {n(done.total)} telefones. {n(done.validNow)} já valem hoje; os demais a partir da data de validade de cada um.{done.removed ? ` ${n(done.removed)} da lista anterior saíram.` : ''}
        </p>
      )}
    </div>
  )
}
