'use client'
import { useState } from 'react'
import { Badge, Card } from '@/components/ui'
import { importFactorPrice, previewFactorPrice, type FactorPricePreview } from './price-actions'

const primary = 'h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50'
const ghost = 'h-10 rounded-[10px] border border-line bg-surface px-4 text-sm text-ink hover:bg-surface-muted disabled:opacity-50'
const br = (d: string) => d.split('-').reverse().join('/')

// The bank's Fator Price (one sheet per bank table, one line per business date): check, then import. The factor goes
// to the bank's table code, so every partner promoter selling that table uses it.
export function FactorPriceImport({ banks, agreements }: { banks: { id: string; name: string }[]; agreements: { id: string; name: string }[] }) {
  const [form, setForm] = useState<FormData | null>(null)
  const [preview, setPreview] = useState<FactorPricePreview | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null)

  async function check(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const f = new FormData(e.currentTarget)
    setBusy(true); setMessage(null); setPreview(null)
    try { const p = await previewFactorPrice(f); setPreview(p); setForm(f); if (!p.ok && p.message) setMessage({ ok: false, text: p.message }) }
    finally { setBusy(false) }
  }
  async function confirm() {
    if (!form) return
    setBusy(true)
    try { const r = await importFactorPrice(form); setMessage({ ok: r.ok, text: r.message }); if (r.ok) setPreview(null) }
    finally { setBusy(false) }
  }
  const linked = preview?.tables.filter(t => t.systemTables.length) ?? []
  const unlinked = preview?.tables.filter(t => !t.systemTables.length) ?? []

  return <Card className="mt-5 p-5">
    <h2 className="font-semibold text-ink">Importar Fator Price do banco</h2>
    <p className="mt-1 text-xs text-muted">Planilha do banco com uma aba por tabela (Convênio = código da tabela) e uma linha por dia útil. O fator vale para todas as promotoras que vendem a tabela. Sábado, domingo e feriado não têm fator: o simulador não mostra a tabela nesses dias.</p>
    <form onSubmit={check} className="mt-3 grid gap-2 md:grid-cols-3">
      <select required name="bank" defaultValue="" className="field"><option value="" disabled>Banco</option>{banks.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
      <select required name="agreement" defaultValue="" className="field"><option value="" disabled>Convênio</option>{agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select>
      <input required type="file" name="files" multiple accept=".xlsx" className="block w-full text-xs" onChange={() => { setPreview(null); setForm(null) }} />
      <div className="md:col-span-3"><button disabled={busy} className={ghost}>{busy && !preview ? 'Lendo...' : 'Conferir'}</button></div>
    </form>
    {message && <p className={`mt-3 text-sm ${message.ok ? 'text-brand-strong' : 'text-red-700'}`}>{message.text}</p>}
    {preview && <div className="mt-4 space-y-3">
      {preview.issues.length > 0 && <div className="rounded-[10px] border border-red-200 bg-red-50 p-3 text-xs text-red-800"><p className="font-semibold">Avisos (corrija antes de importar)</p><ul className="mt-1 list-disc pl-4">{preview.issues.map((x, i) => <li key={i}>{x.sheet}: {x.message}</li>)}</ul></div>}
      <p className="text-sm text-ink">{linked.length} tabelas com fator e tabela no sistema{unlinked.length ? `; ${unlinked.length} sem tabela no sistema (não entram)` : ''}.</p>
      <div className="overflow-x-auto"><table className="w-full text-left text-xs">
        <thead className="text-muted"><tr><th className="py-2">Código</th><th>Dias</th><th>Prazos</th><th>Fator hoje</th><th>Tabelas no sistema (promotora)</th></tr></thead>
        <tbody>{preview.tables.map(t => <tr key={t.code} className="border-t border-line align-top">
          <td className="py-2 font-medium text-ink">{t.code}<span className="block font-normal text-muted">{t.label}</span></td>
          <td className="text-ink-soft">{t.dates} ({br(t.first)} a {br(t.last)})</td>
          <td className="text-ink-soft">{t.terms.join(', ')}</td>
          <td className="text-ink-soft">{t.today ?? <span className="text-muted">sem fator hoje</span>}</td>
          <td className="text-ink-soft">{t.systemTables.length ? t.systemTables.map((s, i) => <span key={i} className="block">{s.name} <span className="text-muted">({s.provider})</span></span>) : <Badge tone="pending">Sem tabela no sistema</Badge>}</td>
        </tr>)}</tbody>
      </table></div>
      {preview.withoutFactor.length > 0 && <details className="text-xs"><summary className="cursor-pointer text-muted">Tabelas deste banco e convênio que ficam sem fator ({preview.withoutFactor.length})</summary><ul className="mt-2 list-disc pl-4 text-ink-soft">{preview.withoutFactor.map((x, i) => <li key={i}>{x.code ? `${x.code} · ` : ''}{x.name} ({x.provider})</li>)}</ul></details>}
      <div className="flex gap-2"><button type="button" disabled={busy || !linked.length || preview.issues.length > 0} onClick={confirm} className={primary}>{busy ? 'Importando...' : 'Importar e publicar'}</button><button type="button" disabled={busy} onClick={() => setPreview(null)} className={ghost}>Cancelar</button></div>
    </div>}
  </Card>
}
