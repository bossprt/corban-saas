'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { parseOfx } from '@/lib/finance/ofx'
import { importStatement } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')

// The OFX is read in the browser; only its transactions go to the server.
export function StatementImportClient({ banks }: { banks: { id: string; label: string }[] }) {
  const router = useRouter()
  const [bank, setBank] = useState(banks[0]?.id ?? '')
  const [file, setFile] = useState<File | null>(null)
  const [msg, setMsg] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function send() {
    if (!file || !bank) { setError('Escolha a conta e o arquivo OFX.'); return }
    setBusy(true); setError(''); setMsg('')
    try {
      const buf = await file.arrayBuffer()
      let text = new TextDecoder('utf-8').decode(buf)
      if (text.includes('�')) text = new TextDecoder('windows-1252').decode(buf)
      const r = parseOfx(text)
      if (r.error === 'not_ofx') { setError('Este arquivo não é um extrato OFX. No banco, exporte o extrato em "OFX" (Money/Quicken).'); return }
      if (r.error === 'no_transactions') { setError('O extrato não tem lançamentos no período.'); return }
      const out = await importStatement({ bankAccount: bank, fileName: file.name, sha: hex(await crypto.subtle.digest('SHA-256', buf)), lines: r.lines })
      if (!out.ok) { setError(out.error); return }
      setMsg(`${r.lines.length} lançamento(s) lidos do extrato.`)
      router.refresh()
    } catch {
      setError('Não foi possível ler o arquivo.')
    } finally { setBusy(false) }
  }

  if (!banks.length) return <p className="text-sm text-muted">Cadastre antes uma conta bancária.</p>
  return (
    <div className="grid gap-3 sm:grid-cols-3">
      <label className={label}>Conta<select value={bank} onChange={e => setBank(e.target.value)} aria-label="Conta bancária do extrato" className="field mt-1.5">{banks.map(b => <option key={b.id} value={b.id}>{b.label}</option>)}</select></label>
      <label className={label}>Extrato (arquivo OFX)<input type="file" accept=".ofx,.OFX" onChange={e => setFile(e.target.files?.[0] ?? null)} className="field mt-1.5" /></label>
      <div className="flex items-end justify-end"><button type="button" onClick={send} disabled={busy || !file} className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">{busy ? 'Importando...' : 'Importar extrato'}</button></div>
      {msg && <p role="status" className="text-sm text-[#15803D] sm:col-span-3">{msg}</p>}
      {error && <div role="alert" className="rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B] sm:col-span-3">{error}</div>}
    </div>
  )
}
