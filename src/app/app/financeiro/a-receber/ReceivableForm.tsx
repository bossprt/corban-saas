'use client'

import Link from 'next/link'
import { useActionState, useState } from 'react'
import { BankAccountSelect } from '@/components/BankAccountSelect'
import { SubmitButton } from '@/components/SubmitButton'
import { Card } from '@/components/ui'
import type { BankOption } from '@/lib/finBankAccounts'
import { brlCents } from '@/lib/finance/labels'
import { parseMoneyInput } from '@/lib/money-input'
import { brlText } from '@/lib/receipts/format'
import { BULK_MAX, totalCents } from '@/lib/receipts/bulk'
import { registerReceiptsBulk, type BulkState } from './actions'

export type ReceivableRow = { proposal_id: string; reference: string; client: string; source_name: string; paid_at: string; expected_amount: string | null }
const field = (v: string | null) => (v ? v.replace('.', ',') : '')

// Ticks, amounts (the expected value, editable) and one confirmation for all. Values are controlled so an error keeps them.
export function ReceivableForm({ rows, canRecord, banks, suggestedBank, today, returnTo }:
  { rows: ReceivableRow[]; canRecord: boolean; banks: BankOption[]; suggestedBank: string; today: string; returnTo: string }) {
  const [state, action] = useActionState<BulkState, FormData>(registerReceiptsBulk, { error: null })
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [amounts, setAmounts] = useState<Record<string, string>>(() => Object.fromEntries(rows.map(r => [r.proposal_id, field(r.expected_amount)])))
  const [receivedOn, setReceivedOn] = useState(today)
  const [note, setNote] = useState('')
  const toggle = (id: string) => setPicked(prev => { const n = new Set(prev); if (n.has(id)) n.delete(id); else n.add(id); return n })
  const all = rows.length > 0 && rows.every(r => picked.has(r.proposal_id))
  const decimals = [...picked].map(id => parseMoneyInput(amounts[id])).filter((v): v is string => typeof v === 'string' && v !== 'invalid')
  const total = totalCents(decimals)

  return (
    <form method="post" action={action} onSubmit={e => {
      if (!picked.size) { e.preventDefault(); return }
      if (!window.confirm(`Registrar o recebimento à vista de ${picked.size} contrato(s), total ${brlCents(total)}, recebido em ${receivedOn.split('-').reverse().join('/')}?`)) e.preventDefault()
    }}>
      <input type="hidden" name="return_to" value={returnTo} />
      <Card className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr>
              {canRecord && <th className="w-10 px-3 py-2"><input type="checkbox" aria-label="Marcar todos" checked={all} onChange={() => setPicked(all ? new Set() : new Set(rows.slice(0, BULK_MAX).map(r => r.proposal_id)))} className="size-4 accent-[var(--brand)]" /></th>}
              <th className="px-3 py-2">Contrato</th><th className="px-3 py-2">Banco ou promotora</th><th className="px-3 py-2">Pago ao cliente</th><th className="px-3 py-2 text-right">Esperado</th>{canRecord && <th className="px-3 py-2 text-right">Recebido (R$)</th>}
            </tr></thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.proposal_id} className="border-t border-line">
                  {canRecord && <td className="px-3 py-2"><input type="checkbox" name="sel" value={r.proposal_id} checked={picked.has(r.proposal_id)} onChange={() => toggle(r.proposal_id)} aria-label={`Marcar ${r.reference || 'contrato'}`} className="size-4 accent-[var(--brand)]" /></td>}
                  <td className="px-3 py-2"><Link href={`/app/propostas/${r.proposal_id}`} className="font-medium text-ink hover:underline">{r.reference || 'Proposta'}</Link><div className="text-xs text-muted">{r.client}</div></td>
                  <td className="px-3 py-2 text-ink-soft">{r.source_name || '—'}</td>
                  <td className="num px-3 py-2 text-ink-soft">{new Date(r.paid_at).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</td>
                  <td className="num px-3 py-2 text-right">{r.expected_amount ? brlText(r.expected_amount) : <span className="text-xs text-muted">sem comissão calculada</span>}</td>
                  {canRecord && <td className="px-3 py-2 text-right">
                    <input name={`amount_${r.proposal_id}`} inputMode="decimal" value={amounts[r.proposal_id] ?? ''} onChange={e => setAmounts(a => ({ ...a, [r.proposal_id]: e.target.value }))}
                      aria-label={`Valor recebido de ${r.reference || 'contrato'}`} placeholder="0,00" className="field h-8 w-28 py-1 text-right" />
                  </td>}
                </tr>
              ))}
              {!rows.length && <tr><td colSpan={6} className="px-3 py-8 text-center text-muted">Nenhum contrato pago esperando a comissão.</td></tr>}
            </tbody>
          </table>
        </div>
        {canRecord && rows.length > 0 && (
          <div className="flex flex-wrap items-end gap-3 border-t border-line bg-surface-muted px-4 py-3">
            <label className="text-[13px] font-medium text-ink-soft">Data em que caiu<input type="date" name="received_on" required max={today} value={receivedOn} onChange={e => setReceivedOn(e.target.value)} className="field mt-1.5 h-9 py-1" /></label>
            <BankAccountSelect banks={banks} suggested={suggestedBank} label="Conta que recebeu" selectClass="field mt-1.5 h-9 py-1" />
            <label className="min-w-[200px] flex-1 text-[13px] font-medium text-ink-soft">Observação<input name="note" maxLength={100} value={note} onChange={e => setNote(e.target.value)} placeholder="Ex.: caiu na conta, banco sem relatório" className="field mt-1.5 h-9 py-1" /></label>
            <span className="flex flex-col items-end gap-1">
              <span className="text-xs text-ink-soft">{picked.size} marcado(s) · <b className="num text-ink">{brlCents(total)}</b></span>
              <SubmitButton disabled={!picked.size} pendingText="Registrando..." className="h-9 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Registrar recebidos</SubmitButton>
            </span>
            {state.error && <p role="alert" className="basis-full rounded-lg bg-[#FDF3DC] px-3 py-2 text-sm text-[#92400E]">{state.error}</p>}
            <p className="basis-full text-xs text-muted">Cada contrato entra igual a uma linha do relatório do banco: compara com o esperado e, se não bater, vai para a Conciliação. Se um falhar, nenhum é registrado.</p>
          </div>
        )}
      </Card>
    </form>
  )
}
