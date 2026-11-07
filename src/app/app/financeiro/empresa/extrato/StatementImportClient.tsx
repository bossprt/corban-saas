'use client'
import { FileDrop } from '@/components/FileDrop'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { parseOfx, sameAccount, type OfxResult } from '@/lib/finance/ofx'
import { importStatement } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')
const day = (iso: string | null) => (iso && /^\d{4}-\d{2}-\d{2}$/.test(iso) ? iso.split('-').reverse().join('/') : iso || 'sem data')
type Bank = { id: string; label: string; account_number: string | null }
type Read = { result: OfxResult; sha: string; name: string }

// The OFX is read in the browser; only its transactions go to the server. Before sending, a file from another account
// or transactions that could not be read are shown, and the user decides (04/11/2026).
export function StatementImportClient({ banks }: { banks: Bank[] }) {
  const router = useRouter()
  const [bank, setBank] = useState(banks[0]?.id ?? '')
  const [file, setFile] = useState<File | null>(null)
  const [check, setCheck] = useState<Read | null>(null)
  const [msg, setMsg] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const chosen = banks.find(b => b.id === bank)

  async function read(): Promise<Read | null> {
    if (!file || !bank) { setError('Escolha a conta e o arquivo OFX.'); return null }
    const buf = await file.arrayBuffer()
    let text = new TextDecoder('utf-8').decode(buf)
    if (text.includes('�')) text = new TextDecoder('windows-1252').decode(buf)
    const result = parseOfx(text)
    if (result.error === 'not_ofx') { setError('Este arquivo não é um extrato OFX. No banco, exporte o extrato em "OFX" (Money/Quicken).'); return null }
    if (result.error === 'no_transactions') { setError('O extrato não tem lançamentos no período.'); return null }
    if (result.error === 'unreadable') { setError(`Nenhum dos ${result.skipped.length} lançamento(s) do arquivo pôde ser lido (data ou valor em formato desconhecido).`); return null }
    return { result, sha: hex(await crypto.subtle.digest('SHA-256', buf)), name: file.name }
  }

  async function send(r: Read) {
    const out = await importStatement({ bankAccount: bank, fileName: r.name, sha: r.sha, lines: r.result.lines })
    if (!out.ok) { setError(out.error); return }
    const known = r.result.lines.length - out.added
    setMsg(`${r.result.lines.length} lido(s) · ${out.added} novo(s)${known > 0 ? ` · ${known} já estava(m) importado(s)` : ''}${r.result.skipped.length ? ` · ${r.result.skipped.length} não lido(s), de fora` : ''}.`)
    setCheck(null)
    router.refresh()
  }

  async function start() {
    setBusy(true); setError(''); setMsg(''); setCheck(null)
    try {
      const r = await read()
      if (!r) return
      if (r.result.skipped.length || sameAccount(r.result.account, chosen?.account_number ?? null) === false) { setCheck(r); return }
      await send(r)
    } catch {
      setError('Não foi possível ler o arquivo.')
    } finally { setBusy(false) }
  }

  async function confirm() {
    if (!check) return
    setBusy(true); setError('')
    try { await send(check) } catch { setError('Não foi possível importar o extrato.') } finally { setBusy(false) }
  }

  if (!banks.length) return <p className="text-sm text-muted">Cadastre antes uma conta bancária.</p>
  const otherAccount = check && sameAccount(check.result.account, chosen?.account_number ?? null) === false
  return (
    <div className="grid gap-3 sm:grid-cols-3">
      <label className={label}>Conta<select value={bank} onChange={e => { setBank(e.target.value); setCheck(null) }} aria-label="Conta bancária do extrato" className="field mt-1.5">{banks.map(b => <option key={b.id} value={b.id}>{b.label}{b.account_number ? ` · c/c ${b.account_number}` : ''}</option>)}</select></label>
      <div className={label}>Extrato (arquivo OFX)<div className="mt-1.5"><FileDrop compact accept=".ofx,.OFX" ariaLabel="Extrato OFX" onChange={fs => { setFile(fs[0] ?? null); setCheck(null) }} /></div></div>
      <div className="flex items-end justify-end"><button type="button" onClick={start} disabled={busy || !file || !!check} className="h-10 rounded-none bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">{busy && !check ? 'Importando...' : 'Importar extrato'}</button></div>
      {check && (
        <div role="alert" className="rounded-none border border-[#FAC775] bg-[#FAEEDA] px-4 py-3 text-sm text-[#854F0B] sm:col-span-3">
          <p className="font-semibold">Confira antes de importar</p>
          {otherAccount && <p className="mt-1">O arquivo é da conta {check.result.account}, mas você escolheu {chosen?.label} (c/c {chosen?.account_number}).</p>}
          {check.result.skipped.length > 0 && (
            <>
              <p className="mt-1">{check.result.skipped.length} de {check.result.skipped.length + check.result.lines.length} lançamento(s) do arquivo não puderam ser lidos e ficarão de fora:</p>
              <ul className="mt-1 text-xs">
                {check.result.skipped.slice(0, 10).map((s, i) => <li key={i}>· {s.reason === 'date' ? `data inválida (${s.date || 'vazia'})` : day(s.date)} · valor &quot;{s.amount ?? ''}&quot;{s.reason === 'amount' ? ' (formato não reconhecido)' : ''}</li>)}
                {check.result.skipped.length > 10 && <li>· e mais {check.result.skipped.length - 10}</li>}
              </ul>
            </>
          )}
          <div className="mt-2 flex flex-wrap gap-2">
            <button type="button" onClick={() => setCheck(null)} className="h-9 rounded-none border border-[#BA7517] bg-surface px-3 text-sm text-ink">Trocar arquivo ou conta</button>
            <button type="button" onClick={confirm} disabled={busy} className="h-9 rounded-none bg-[#854F0B] px-3 text-sm font-semibold text-white disabled:opacity-60">{busy ? 'Importando...' : `Importar mesmo assim (${check.result.lines.length})`}</button>
          </div>
        </div>
      )}
      {msg && <p role="status" className="text-sm text-[#15803D] sm:col-span-3">{msg}</p>}
      {error && <div role="alert" className="rounded-none border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B] sm:col-span-3">{error}</div>}
    </div>
  )
}
