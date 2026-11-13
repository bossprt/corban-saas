'use client'
import { FileDrop } from '@/components/FileDrop'

import { useEffect, useRef, useState, useTransition } from 'react'
import Link from 'next/link'
import { Download, Upload } from 'lucide-react'
import { Badge, Button } from '@/components/ui'
import { formatCpf } from '@/lib/cpf'
import { brlText } from '@/lib/receipts/format'
import { importContracts, previewContracts, type ImportResult } from './actions'

const money = (v: string | null) => (v === null ? '—' : brlText(v))

type Pick = { table?: string; seller?: string }

// Two steps on the same file: "Conferir" shows what each line becomes; "Importar" writes the lines that passed.
// A PDF layout names no table: each line lists the tables that fit and the owner picks one (and the seller).
// The Bevicred layout has no file: "Buscar na Bevicred" reads the company's contracts of the chosen period; a table or
// seller picked there is remembered, and a line can be left out ("Não importar").
// "Buscar na Bevicred" on the Esteira opens it with autoBevicred: the Bevicred layout, already searching.
export function ContractImportClient({ layouts, autoBevicred = false }: { layouts: { key: string; label: string; pdf: boolean; api: boolean; model?: boolean }[]; autoBevicred?: boolean }) {
  const [layout, setLayout] = useState((autoBevicred && layouts.find(l => l.api)?.key) || (layouts[0]?.key ?? ''))
  const [file, setFile] = useState<File | null>(null)
  const [result, setResult] = useState<ImportResult | null>(null)
  const [picks, setPicks] = useState<Record<number, Pick>>({})
  // PDF layouts: the agreement chosen for each product block of the report (index -> agreement id).
  const [agreementOf, setAgreementOf] = useState<Record<number, string>>({})
  const [busy, start] = useTransition()
  const pdf = layouts.find(l => l.key === layout)?.pdf ?? false
  const api = layouts.find(l => l.key === layout)?.api ?? false
  // A promoter's report has its own columns: the Corban template does not apply.
  const model = layouts.find(l => l.key === layout)?.model ?? true
  const [days, setDays] = useState('7')

  const send = (action: typeof previewContracts) => start(async () => {
    if (!file && !api) return
    const fd = new FormData()
    fd.set('layout', layout)
    if (api) fd.set('days', days)
    else if (file) fd.set('file', file)
    // The Bevicred layout sends the picks by ADE (its lines may shift between the search and the import).
    const adeOf = new Map((result?.lines ?? []).map(l => [String(l.line), l.ade]))
    for (const [k, a] of Object.entries(agreementOf)) if (a) fd.set(`agreement:${k}`, a)
    for (const [line, p] of Object.entries(picks)) {
      const key = api ? adeOf.get(line) : line
      if (!key) continue
      if (p.table) fd.set(`table:${key}`, p.table)
      if (p.seller) fd.set(`seller:${key}`, p.seller)
    }
    const r = await action(fd)
    setResult(r)
    // A kept "Não importar" follows its ADE when the lines shift.
    const skippedAde = new Set((result?.lines ?? []).filter(l => picks[l.line]?.table === 'skip').map(l => l.ade))
    setPicks(Object.fromEntries(r.lines.map(l => [l.line, {
      table: l.tableId ?? (l.status === 'skip' && skippedAde.has(l.ade) ? 'skip' : undefined), seller: l.sellerId,
    }])))
  })
  const started = useRef(false)
  useEffect(() => {
    if (autoBevicred && api && !started.current) { started.current = true; send(previewContracts) }
  })
  const pick = (line: number, p: Pick) => setPicks(prev => ({ ...prev, [line]: { ...prev[line], ...p } }))
  const reset = () => { setResult(null); setPicks({}); setAgreementOf({}) }

  const lines = result?.lines ?? []
  const skipped = (l: ImportResult['lines'][number]) => l.status === 'skip' || picks[l.line]?.table === 'skip'
  const chosen = (l: ImportResult['lines'][number]) => l.status === 'choose' && !!picks[l.line]?.table && !skipped(l)
  const ok = lines.filter(l => (l.status === 'ok' && !skipped(l)) || chosen(l)).length
  const toChoose = lines.filter(l => l.status === 'choose' && !chosen(l) && !skipped(l)).length
  const skips = lines.filter(skipped).length
  const exists = lines.filter(l => l.status === 'exists').length
  const errors = lines.filter(l => l.status === 'error').length
  const done = result?.done

  return (
    <div className="space-y-5 text-sm">
      <div className="flex flex-wrap items-end gap-3">
        <label className="block text-[13px] font-medium text-ink-soft">Layout
          <select value={layout} onChange={e => { setLayout(e.target.value); reset() }} className="field mt-1.5 w-56">
            {layouts.map(l => <option key={l.key} value={l.key}>{l.label}</option>)}
          </select>
        </label>
        {api ? (
          <label className="block flex-1 text-[13px] font-medium text-ink-soft">Período (data de importação na Bevicred)
            <select value={days} onChange={e => { setDays(e.target.value); reset() }} className="field mt-1.5 block w-48">
              <option value="7">Últimos 7 dias</option><option value="15">Últimos 15 dias</option><option value="30">Últimos 30 dias</option>
            </select>
          </label>
        ) : (
          <div className="block min-w-64 flex-1 text-[13px] font-medium text-ink-soft">{pdf ? 'Relatório do banco (.pdf)' : 'Planilha (.xlsx ou .csv)'}
            <div className="mt-1.5"><FileDrop key={pdf ? 'pdf' : 'sheet'} compact accept={pdf ? '.pdf' : '.xlsx,.csv'} ariaLabel={pdf ? 'Relatório de contratos em PDF' : 'Planilha de contratos'} onChange={fs => { setFile(fs[0] ?? null); reset() }} /></div>
          </div>
        )}
        {!pdf && !api && model && (
          <a href={`/api/propostas/importar/modelo?layout=${layout}`} className="inline-flex h-10 items-center gap-1.5 rounded-[10px] border border-line px-4 font-medium text-ink-soft hover:bg-surface-muted">
            <Download size={16} aria-hidden />Baixar modelo
          </a>
        )}
        <Button type="button" disabled={(!file && !api) || busy} onClick={() => send(previewContracts)}>
          <Upload size={16} aria-hidden />{busy && !done ? (api ? 'Buscando…' : 'Conferindo…') : api ? 'Buscar na Bevicred' : 'Conferir'}
        </Button>
      </div>

      {result?.notices?.map(n => <p key={n} role="alert" className="rounded-[10px] border border-line bg-surface-muted px-4 py-2 text-ink-soft">{n}</p>)}
      {result?.error && <p role="alert" className="rounded-[10px] border border-diverged/40 bg-diverged/5 px-4 py-3 font-medium text-diverged">{result.error}</p>}
      {result && result.fileIssues.length > 0 && (
        <div role="alert" className="rounded-[10px] border border-diverged/40 bg-diverged/5 px-4 py-3 text-diverged">
          <p className="font-semibold">A planilha não pode ser lida assim:</p>
          <ul className="mt-1 list-disc pl-5">{result.fileIssues.map(i => <li key={i}>{i}</li>)}</ul>
        </div>
      )}
      {result && result.ignored.length > 0 && <p className="text-xs text-muted">Colunas ignoradas (não são campos do Corban): {result.ignored.join(', ')}</p>}
      {result?.products && <p className="text-ink-soft">{result.products.length} produto(s) no relatório. Cada produto vai para um convênio; escolha a tabela de cada contrato (o relatório não diz se é Comissionado ou Efetivo). Os contratos entram como pagos, na data do crédito ao cliente; a comissão entra pela importação de recebimento.</p>}
      {result?.tooMany && <p className="font-medium text-diverged">A planilha passa de 500 linhas: só as 500 primeiras foram lidas. Divida o arquivo.</p>}

      {done && (
        <p role="status" className="rounded-[10px] border border-received/40 bg-received/5 px-4 py-3 font-medium text-ink">
          Importação concluída: {done.created} cadastrado(s), {done.existed} já existia(m){done.updated ? ` (${done.updated} com a etapa atualizada pelo relatório)` : ''}, {done.failed} com erro.{' '}
          <Link href="/app/propostas" className="text-brand hover:text-brand-strong">Ver na esteira</Link>
        </p>
      )}

      {lines.length > 0 && (
        <>
          {!done && (
            <div className="flex flex-wrap items-center justify-between gap-3">
              <p className="text-ink-soft">
                <span className="font-semibold text-ink">{lines.length}</span> linha(s): {ok} para cadastrar, {exists} já no Corban, {errors} com erro{skips ? `, ${skips} não importar` : ''}{toChoose ? `, ${toChoose} sem tabela escolhida` : ''}.
              </p>
              <Button type="button" disabled={busy || (errors > 0 && !api) || toChoose > 0 || ok + (api ? exists : 0) === 0} onClick={() => send(importContracts)}>
                {busy ? 'Importando…' : api ? `Importar ${ok} e atualizar ${exists}` : `Importar ${ok} contrato(s)`}
              </Button>
            </div>
          )}
          {!done && errors > 0 && <p className="text-diverged">{api ? 'As linhas com erro ficam de fora; as outras são importadas.' : 'Corrija as linhas com erro na planilha e confira de novo. Nada foi gravado.'}</p>}
          <div className="overflow-x-auto rounded-[10px] border border-line">
            <table className="w-full min-w-[900px] text-left text-[13px]">
              <thead className="bg-surface-muted text-xs text-muted">
                <tr>{['Linha', 'Cliente', 'CPF', 'Tabela', 'Prazo', 'Valor', 'ADE', 'Etapa', 'Vendedor', 'Situação'].map(h => <th key={h} className="px-3 py-2 font-medium">{h}</th>)}</tr>
              </thead>
              <tbody>
                {(result?.products ? result.products.map((p, k) => ({ k, p, ls: lines.filter(l => l.product === k) })) : [{ k: -1, p: null, ls: lines }]).flatMap(({ k, p, ls }) => [
                  ...(p ? [<ProductRow key={`p${k}`} k={k} p={p} agreements={result?.agreements ?? []} value={agreementOf[k] ?? p.agreementId ?? ''} done={!!done} busy={busy}
                    lines={ls} onAgreement={a => setAgreementOf(prev => ({ ...prev, [k]: a }))} onApply={() => send(previewContracts)}
                    onTableAll={t => setPicks(prev => { const next = { ...prev }; for (const l of ls) if (l.tableOptions?.some(o => o.id === t)) next[l.line] = { ...next[l.line], table: t }; return next })} />] : []),
                  ...ls.map(l => (
                  <tr key={l.line} className="border-t border-line align-top">
                    <td className="num px-3 py-2 text-muted">{l.line}</td>
                    <td className="px-3 py-2 text-ink">{l.name || '—'}{l.origin && <span className="block text-xs text-muted">{l.origin}</span>}</td>
                    <td className="num px-3 py-2">{l.cpf.length === 11 ? formatCpf(l.cpf) : l.cpf || '—'}</td>
                    <td className="px-3 py-2">
                      {l.tableOptions && !done && l.status !== 'error' ? (
                        <select aria-label={`Tabela da linha ${l.line}`} value={picks[l.line]?.table ?? ''} onChange={e => pick(l.line, { table: e.target.value || undefined })} className="field h-9 w-56 text-[13px]">
                          {(l.tableOptions.length > 1 || api) && <option value="">Escolher ({l.tableOptions.length} servem)</option>}
                          {l.tableOptions.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
                          {api && <option value="skip">Não importar esta linha</option>}
                        </select>
                      ) : l.table || '—'}
                      {l.hint && <span className="mt-1 block text-xs text-muted">Bevicred: {l.hint}</span>}
                    </td>
                    <td className="num px-3 py-2">{l.term ?? '—'}</td>
                    <td className="num px-3 py-2">{money(l.amount)}</td>
                    <td className="num px-3 py-2">{l.ade || '—'}</td>
                    <td className="px-3 py-2">{l.stage ?? 'Automática'}</td>
                    <td className="px-3 py-2">
                      {result?.sellers && !done && (l.status === 'ok' || l.status === 'choose') ? (
                        <select aria-label={`Vendedor da linha ${l.line}`} value={picks[l.line]?.seller ?? ''} onChange={e => pick(l.line, { seller: e.target.value || undefined })} className="field h-9 w-48 text-[13px]">
                          <option value="">Sem vendedor</option>
                          {result.sellers.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
                        </select>
                      ) : result?.sellers ? result.sellers.find(s => s.id === picks[l.line]?.seller)?.name ?? '—' : l.seller || '—'}
                      {l.partner && <span className="mt-1 block text-xs text-muted">Parceiro: {l.partner}</span>}
                    </td>
                    <td className="px-3 py-2">
                      <Badge tone={skipped(l) ? 'neutral' : l.status === 'ok' || chosen(l) ? 'received' : l.status === 'exists' || l.status === 'choose' ? 'pending' : 'diverged'}>
                        {skipped(l) ? 'Não importar' : l.status === 'ok' || chosen(l) ? (done ? 'Cadastrado' : 'OK') : l.status === 'exists' ? 'Já existe' : l.status === 'choose' ? 'Escolher tabela' : 'Erro'}
                      </Badge>
                      {l.messages.filter(m => m !== 'Cadastrado' && !(m === 'Escolha a tabela' && chosen(l)) && !(m.startsWith('Sem vendedor') && !done && picks[l.line]?.seller)).map(m => <span key={m} className="mt-1 block text-xs text-ink-soft">{m}</span>)}
                    </td>
                  </tr>
                ))])}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  )
}

type Line = ImportResult['lines'][number]
// The header of one product block of a PDF report: its agreement (suggested from the product name, or chosen) and
// "apply to all" for the table of its contracts. Changing the agreement needs "Conferir de novo" (the tables change).
function ProductRow({ k, p, agreements, value, done, busy, lines, onAgreement, onApply, onTableAll }: {
  k: number; p: NonNullable<ImportResult['products']>[number]; agreements: { id: string; name: string }[]; value: string; done: boolean; busy: boolean
  lines: Line[]; onAgreement: (id: string) => void; onApply: () => void; onTableAll: (tableId: string) => void
}) {
  const changed = value !== (p.agreementId ?? '')
  const options = [...new Map(lines.flatMap(l => l.tableOptions ?? []).map(o => [o.id, o])).values()]
  return <tr className="border-t border-line bg-surface-muted/70">
    <td colSpan={10} className="px-3 py-2">
      <div className="flex flex-wrap items-center gap-3">
        <strong className="text-ink">{p.label}</strong><span className="text-xs text-muted">{lines.length} contrato(s)</span>
        {done ? <span className="text-ink-soft">{agreements.find(a => a.id === value)?.name ?? '—'}</span> : <>
          <select aria-label={`Convênio do produto ${k + 1}`} value={value} onChange={e => onAgreement(e.target.value)} className={`field h-9 w-56 text-[13px] ${value ? '' : 'border-[#F0A020] bg-[#FFF9EE]'}`}>
            <option value="" disabled>Escolha o convênio</option>
            {agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select>
          {p.suggested && !changed && <Badge tone="pending">sugerido</Badge>}
          {changed && <button type="button" disabled={busy || !value} onClick={onApply} className="h-9 rounded-[10px] border border-line bg-surface px-3 text-[13px] text-ink hover:bg-surface-muted disabled:opacity-50">Conferir de novo com este convênio</button>}
          {!changed && options.length > 1 && <label className="ml-auto text-xs text-muted">Aplicar a todas
            <select aria-label={`Tabela de todos os contratos do produto ${k + 1}`} defaultValue="" onChange={e => { if (e.target.value) onTableAll(e.target.value) }} className="field ml-2 inline-block h-9 w-64 text-[13px]">
              <option value="">Escolha a tabela</option>
              {options.map(o => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select></label>}
        </>}
      </div>
    </td>
  </tr>
}
