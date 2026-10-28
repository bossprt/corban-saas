'use client'
import { FileDrop } from '@/components/FileDrop'

import { useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { readLegacyFileInBrowser, type LegacySheet } from '@/lib/legacy/browser-read'
import { readReceiptPdf } from '@/lib/receipts/pdf'
import { mergeReportFiles } from '@/lib/receipts/parse'
import { checkReceiptFile, importReceiptFile, inspectReceiptFile, type FileCheck } from '../actions'

type Source = { value: string; label: string }
const FIELDS: { key: 'ade' | 'amount' | 'installment' | 'paid_on' | 'bank'; label: string; required?: boolean; hint?: string }[] = [
  { key: 'ade', label: 'Contrato (ADE ou nº da proposta)', required: true },
  { key: 'amount', label: 'Valor da comissão', required: true },
  { key: 'installment', label: 'Parcela', hint: 'diferido; sem ela, vale a próxima parcela em aberto' },
  { key: 'paid_on', label: 'Data do pagamento' },
  { key: 'bank', label: 'Banco (só para consulta)' },
]
const label = 'text-[13px] font-medium text-ink-soft'
const CHECK_TEXT: Record<Exclude<FileCheck['result'], 'ready'>, string> = {
  no_seller: 'Sem vendedor: a comissão ainda não foi calculada. Informe o vendedor em Contratos antes de importar.',
  no_calc: 'Sem comissão calculada (confira a tabela ou o grupo do vendedor).',
  received: 'Comissão já recebida em outro relatório.',
  not_found: 'Contrato não encontrado neste banco ou promotora.',
  ambiguous: 'Mais de um contrato com este número.',
}
const thisMonth = () => new Date().toISOString().slice(0, 7)
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')

// PDF (text layer) or spreadsheet. A PDF is recognised by its first bytes, never by the name alone.
async function readOne(file: File): Promise<LegacySheet | { error: string }> {
  const head = new Uint8Array(await file.slice(0, 5).arrayBuffer())
  if (String.fromCharCode(...head) !== '%PDF-') return readLegacyFileInBrowser(file)
  const buf = await file.arrayBuffer()
  return readReceiptPdf(new Uint8Array(buf), hex(await crypto.subtle.digest('SHA-256', buf)))
}

// Two steps on the same file: read the columns (in the browser, nothing stored), then import with the chosen columns.
// Only the chosen columns travel to the server, so a report of any size stays under the request limit.
export function ReceiptImportClient({ sources, bankAccounts, suggestedBank }: { sources: Source[]; bankAccounts: { id: string; label: string }[]; suggestedBank: string }) {
  const [bank, setBank] = useState(suggestedBank)
  const [files, setFiles] = useState<File[]>([])
  const [source, setSource] = useState('')
  const [kind, setKind] = useState('upfront')
  const [month, setMonth] = useState(thisMonth)
  const [declared, setDeclared] = useState('')
  const [inspect, setInspect] = useState<{ sheet: LegacySheet; fileOf: number[]; mapping: unknown } | null>(null)
  const [cols, setCols] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [issues, setIssues] = useState<{ row: number; message: string }[]>([])
  const [busy, setBusy] = useState(false)
  const [checked, setChecked] = useState<{ key: string; lines: FileCheck[] } | null>(null)

  // As soon as the contract column is known, every number of the file is checked (ready, or why not).
  const adeCol = inspect ? inspect.sheet.headers.indexOf(cols.ade ?? '') : -1
  const amountCol = inspect ? inspect.sheet.headers.indexOf(cols.amount ?? '') : -1
  // More than one file (à vista + bônus): one line per contract, the amounts of the files added together.
  const body = useMemo(() => {
    if (!inspect) return []
    const rows = inspect.sheet.body.filter(r => r.some(c => c !== ''))
    return files.length > 1 && adeCol >= 0 && amountCol >= 0 ? mergeReportFiles(inspect.sheet.body, inspect.fileOf, adeCol, amountCol).filter(r => r.some(c => c !== '')) : rows
  }, [inspect, files.length, adeCol, amountCol])
  const checkKey = inspect && adeCol >= 0 ? `${source}|${kind}|${adeCol}|${inspect.sheet.sha}` : null
  useEffect(() => {
    if (!inspect || !checkKey) return
    let live = true
    const ades = body.map(r => String(r[adeCol] ?? '').trim()).filter(Boolean)
    checkReceiptFile({ source, kind, ades }).then(r => { if (live && r.ok) setChecked({ key: checkKey, lines: r.lines }) })
    return () => { live = false }
  }, [inspect, checkKey, adeCol, source, kind, body])
  const check = checked && checked.key === checkKey ? checked.lines : null
  const problems = (check ?? []).filter(c => c.result !== 'ready')
  const groups = (Object.keys(CHECK_TEXT) as (keyof typeof CHECK_TEXT)[]).map(k => ({ k, ades: problems.filter(p => p.result === k).map(p => p.ade) })).filter(g => g.ades.length)

  async function readColumns() {
    if (!files.length || !source) { setError('Escolha a fonte pagadora e o arquivo.'); return }
    setBusy(true); setError(''); setIssues([]); setInspect(null)
    try {
      const sheets: LegacySheet[] = []
      for (const f of files) {
        const one = await readOne(f)
        if ('error' in one) { setError(files.length > 1 ? `${f.name}: ${one.error}` : one.error); return }
        // Trailing blank rows (common in spreadsheets) are not part of the report.
        let end = one.body.length
        while (end > 0 && !one.body[end - 1].some(c => c !== '')) end--
        one.body = one.body.slice(0, end)
        sheets.push(one)
      }
      if (sheets.some(x => x.headers.join('|') !== sheets[0].headers.join('|'))) { setError('Os arquivos têm colunas diferentes. Envie juntos só relatórios do mesmo modelo (ex.: à vista e bônus do mesmo banco).'); return }
      // Several files are one report: the rows one after the other; the fingerprint covers every file.
      const sheet: LegacySheet = sheets.length === 1 ? sheets[0] : {
        headers: sheets[0].headers, headerRow: sheets[0].headerRow, body: sheets.flatMap(x => x.body),
        sha: hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(sheets.map(x => x.sha).sort().join('|')))),
      }
      const fileOf = sheets.flatMap((x, i) => x.body.map(() => i))
      const r = await inspectReceiptFile({ source, kind, headers: sheet.headers })
      if (!r.ok) { setError(r.error); return }
      setInspect({ sheet, fileOf, mapping: r.mapping })
      setCols(Object.fromEntries(Object.entries(r.mapping ?? {}).filter(([, v]) => v)) as Record<string, string>)
    } catch {
      setError('Não foi possível ler o arquivo.')
    } finally { setBusy(false) }
  }

  async function runImport() {
    if (!inspect || !files.length) return
    setBusy(true); setError(''); setIssues([])
    try {
      const { sheet } = inspect
      const chosen = [...new Set(FIELDS.map(f => cols[f.key]).filter(Boolean))]
      const idx = chosen.map(h => sheet.headers.indexOf(h))
      const r = await importReceiptFile({
        source, kind, month, declaredTotal: declared, fileName: files.map(f => f.name).join(' + '), sha: sheet.sha, bankAccount: bank,
        mapping: { ade: cols.ade ?? '', amount: cols.amount ?? '', installment: cols.installment || undefined, paid_on: cols.paid_on || undefined, bank: cols.bank || undefined },
        headerRow: sheet.headerRow, headers: chosen, body: body.map(row => idx.map(i => String(row[i] ?? ''))),
      })
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
        <label className={label}>Conta que recebeu <span className="font-normal text-muted">conta da empresa onde o dinheiro entrou</span>
          <select value={bank} onChange={e => setBank(e.target.value)} className="field mt-1.5">
            <option value="">Não informar agora</option>
            {bankAccounts.map(b => <option key={b.id} value={b.id}>{b.label}</option>)}
          </select>
        </label>
        <div className={`${label} sm:col-span-2`}>Arquivo (XLSX, XLS, CSV ou PDF) <span className="font-normal text-muted">pode escolher mais de um do mesmo pagamento, ex.: à vista e bônus; o valor de cada contrato é somado</span>
          <div className="mt-1.5"><FileDrop compact multiple accept=".xlsx,.xls,.csv,.txt,.pdf" ariaLabel="Arquivo do relatório" onChange={fs => { setFiles(fs.slice(0, 10)); setInspect(null) }} /></div>
        </div>
      </div>
      <div className="flex justify-end">
        <button type="button" onClick={readColumns} disabled={busy || !files.length || !source} className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted disabled:opacity-50">Ler colunas do arquivo</button>
      </div>

      {inspect && (
        <div className="grid gap-4 border-t border-line pt-5">
          <p className="text-sm text-ink">
            {inspect.sheet.body.length} linha(s) após os títulos{files.length > 1 ? ` em ${files.length} arquivos` : ''}. {inspect.mapping ? 'Modelo de colunas salvo para esta fonte e tipo: confira e importe.' : 'Primeira vez desta fonte e tipo: diga qual coluna é qual. O modelo fica salvo.'}
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            {FIELDS.filter(f => kind === 'deferred' || f.key !== 'installment').map(f => (
              <label key={f.key} className={label}>{f.label}{f.required && ' *'}{f.hint && <span className="block font-normal text-muted">{f.hint}</span>}
                <select value={cols[f.key] ?? ''} onChange={e => setCols(c => ({ ...c, [f.key]: e.target.value }))} className="field mt-1.5">
                  <option value="">{f.required ? 'Escolha a coluna' : 'Não tem'}</option>
                  {inspect.sheet.headers.filter(Boolean).map(h => <option key={h} value={h}>{h}</option>)}
                </select>
              </label>
            ))}
          </div>
          {/* Every line of the file (owner, 20/10/2026: five sample lines looked like only five would be imported). */}
          <p className="text-[13px] font-medium text-ink-soft">Prévia: {body.length} linha(s){files.length > 1 ? ' (contratos repetidos nos arquivos já somados)' : ' do arquivo'}</p>
          <div className="max-h-[420px] overflow-auto rounded-[10px] border border-line">
            <table className="w-full text-left text-[12px]">
              <thead className="sticky top-0 bg-surface-muted text-muted"><tr>{inspect.sheet.headers.map((h, i) => <th key={i} className="whitespace-nowrap px-3 py-2 font-medium">{h}</th>)}</tr></thead>
              <tbody>{body.slice(0, 1000).map((r, i) => <tr key={i} className="border-t border-line">{inspect.sheet.headers.map((_, j) => <td key={j} className="whitespace-nowrap px-3 py-1.5 text-ink-soft">{r[j]}</td>)}</tr>)}</tbody>
            </table>
          </div>
          {check && (
            <div role="status" className={`rounded-[10px] border px-4 py-3 text-sm ${problems.length ? 'border-[#F3D9A4] bg-[#FDF3DC] text-[#92400E]' : 'border-[#BBE5C8] bg-[#E3F5E9] text-[#15803D]'}`}>
              <p className="font-semibold">O arquivo tem {check.length} contrato(s): {check.length - problems.length} pronto(s) para conferir{problems.length ? `, ${problems.length} com pendência` : ''}.</p>
              {groups.map(g => (
                <p key={g.k} className="mt-1.5">{g.ades.length} — {CHECK_TEXT[g.k]} <span className="num block text-xs">{g.ades.join(', ')}</span></p>
              ))}
              {groups.some(g => g.k === 'no_seller') && <Link href="/app/contratos?vendedor=none&n=100" className="mt-2 inline-block font-medium underline">Abrir os contratos sem vendedor</Link>}
              {problems.length > 0 && <p className="mt-2 text-xs">Se importar assim, essas linhas ficam &quot;A resolver&quot; e o relatório só pode ser confirmado depois de resolvidas ou ignoradas.</p>}
            </div>
          )}
          <div className="flex justify-end">
            <button type="button" onClick={runImport} disabled={busy || !cols.ade || !cols.amount} className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">{problems.length ? 'Importar mesmo assim' : 'Importar para conferência'}</button>
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
