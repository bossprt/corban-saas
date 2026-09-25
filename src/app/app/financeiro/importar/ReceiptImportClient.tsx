'use client'

import { useState } from 'react'
import { importReceiptFile, inspectReceiptFile, type InspectResult } from '../actions'

type Source = { value: string; label: string }
const FIELDS: { key: 'ade' | 'amount' | 'installment' | 'paid_on' | 'bank'; label: string; required?: boolean; hint?: string }[] = [
  { key: 'ade', label: 'Contrato (ADE ou nº da proposta)', required: true },
  { key: 'amount', label: 'Valor da comissão', required: true },
  { key: 'installment', label: 'Parcela', hint: 'diferido; sem ela, vale a próxima parcela em aberto' },
  { key: 'paid_on', label: 'Data do pagamento' },
  { key: 'bank', label: 'Banco (só para consulta)' },
]
const label = 'text-[13px] font-medium text-ink-soft'
const thisMonth = () => new Date().toISOString().slice(0, 7)

// Two steps on the same file: read the columns (nothing stored), then import with the chosen columns.
export function ReceiptImportClient({ sources }: { sources: Source[] }) {
  const [file, setFile] = useState<File | null>(null)
  const [source, setSource] = useState('')
  const [kind, setKind] = useState('upfront')
  const [month, setMonth] = useState(thisMonth)
  const [declared, setDeclared] = useState('')
  const [inspect, setInspect] = useState<Extract<InspectResult, { ok: true }> | null>(null)
  const [cols, setCols] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [issues, setIssues] = useState<{ row: number; message: string }[]>([])
  const [busy, setBusy] = useState(false)

  const base = () => {
    const fd = new FormData()
    fd.set('file', file!); fd.set('source', source); fd.set('kind', kind)
    return fd
  }

  async function readColumns() {
    if (!file || !source) { setError('Escolha a fonte pagadora e o arquivo.'); return }
    setBusy(true); setError(''); setIssues([]); setInspect(null)
    try {
      const r = await inspectReceiptFile(base())
      if (!r.ok) { setError(r.error); return }
      setInspect(r)
      setCols(Object.fromEntries(Object.entries(r.mapping ?? {}).filter(([, v]) => v)) as Record<string, string>)
    } finally { setBusy(false) }
  }

  async function runImport() {
    setBusy(true); setError(''); setIssues([])
    try {
      const fd = base()
      fd.set('month', month); fd.set('declared_total', declared)
      for (const f of FIELDS) fd.set(`col_${f.key}`, cols[f.key] ?? '')
      const r = await importReceiptFile(fd)
      // On success the action redirects; only failures come back here.
      if (r && !r.ok) { setError(r.error); setIssues(r.issues ?? []) }
    } finally { setBusy(false) }
  }

  return (
    <div className="grid gap-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <label className={label}>Fonte pagadora
          <select value={source} onChange={e => { setSource(e.target.value); setInspect(null) }} className="field mt-1.5" required>
            <option value="" disabled>Banco ou promotora que pagou</option>
            {sources.map(s => <option key={s.value} value={s.value}>{s.label}</option>)}
          </select>
        </label>
        <label className={label}>Tipo do relatório
          <select value={kind} onChange={e => { setKind(e.target.value); setInspect(null) }} className="field mt-1.5">
            <option value="upfront">À vista (contratos pagos)</option>
            <option value="deferred">Diferido (parcelas)</option>
            <option value="chargeback">Estorno</option>
          </select>
        </label>
        <label className={label}>Mês de referência<input type="month" value={month} onChange={e => setMonth(e.target.value)} className="field mt-1.5" /></label>
        <label className={label}>Total do relatório <span className="font-normal text-muted">opcional; se informado, tem de bater com a soma das linhas</span>
          <input inputMode="decimal" value={declared} onChange={e => setDeclared(e.target.value)} placeholder="1.234,56" className="field mt-1.5" />
        </label>
        <label className={`${label} sm:col-span-2`}>Arquivo (XLSX, XLS ou CSV)
          <input type="file" accept=".xlsx,.xls,.csv,.txt" onChange={e => { setFile(e.target.files?.[0] ?? null); setInspect(null) }} className="field mt-1.5" />
        </label>
      </div>
      <div className="flex justify-end">
        <button type="button" onClick={readColumns} disabled={busy || !file || !source} className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted disabled:opacity-50">Ler colunas do arquivo</button>
      </div>

      {inspect && (
        <div className="grid gap-4 border-t border-line pt-5">
          <p className="text-sm text-ink">
            {inspect.rowCount} linha(s) após os títulos. {inspect.mapping ? 'Modelo de colunas salvo para esta fonte e tipo: confira e importe.' : 'Primeira vez desta fonte e tipo: diga qual coluna é qual. O modelo fica salvo.'}
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            {FIELDS.filter(f => kind === 'deferred' || f.key !== 'installment').map(f => (
              <label key={f.key} className={label}>{f.label}{f.required && ' *'}{f.hint && <span className="block font-normal text-muted">{f.hint}</span>}
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
            <button type="button" onClick={runImport} disabled={busy || !cols.ade || !cols.amount} className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">Importar para conferência</button>
          </div>
        </div>
      )}

      {error && (
        <div role="alert" className="rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">
          {error}
          {issues.length > 0 && <ul className="mt-2 list-disc pl-5">{issues.map(i => <li key={i.row}>Linha {i.row}: {i.message}</li>)}</ul>}
        </div>
      )}
    </div>
  )
}
