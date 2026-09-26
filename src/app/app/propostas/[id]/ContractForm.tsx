'use client'

import { useState } from 'react'
import { Lock, Pencil, X } from 'lucide-react'
import { Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { updateContract } from './contract-actions'

type Option = { id: string; label: string }
export type ContractData = {
  id: string; table_version_id: string | null; seller_id: string | null; requested: string; released: string; installment: string; term: string
  ade: string | null
}
const lbl = 'text-[13px] font-medium text-ink-soft'

// The contract file is its form (owner decision 26/09/2026, same as the client file): it opens locked and "Editar
// contrato" unlocks it in place. Saving recalculates the commission; a paid contract asks for the reason. Nothing
// changes once the seller received the commission (the database refuses it too).
export function ContractForm({ c, tables, sellers, canEdit, paid, received }: {
  c: ContractData; tables: Option[]; sellers: Option[]; canEdit: boolean; paid: boolean; received: boolean
}) {
  const [editing, setEditing] = useState(false)
  const [round, setRound] = useState(0)
  const locked = !editing
  return (
    <Card id="contrato" className="mt-4">
      <form action={updateContract}>
        <input type="hidden" name="proposal_id" value={c.id} />
        <CardHeader title="Contrato" action={received
          ? <span className="inline-flex items-center gap-1.5 text-xs text-muted"><Lock size={14} aria-hidden />Vendedor já recebeu: não muda mais</span>
          : canEdit ? (locked
            ? <button type="button" onClick={() => setEditing(true)} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm font-medium text-ink hover:bg-surface-muted"><Pencil size={15} aria-hidden />Editar contrato</button>
            : <button type="button" onClick={() => { setEditing(false); setRound(r => r + 1) }} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink-soft hover:bg-surface-muted"><X size={15} aria-hidden />Cancelar</button>)
            : undefined} />
        <fieldset key={round} disabled={locked} className="grid gap-3 px-5 pb-5 pt-3 md:grid-cols-4">
          <label className={`${lbl} md:col-span-2`}>Banco e tabela
            <select name="table_version_id" defaultValue={c.table_version_id ?? ''} required className="field mt-1.5">
              {!tables.some(t => t.id === c.table_version_id) && c.table_version_id && <option value={c.table_version_id}>Vigência do contrato</option>}
              {tables.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
            </select>
          </label>
          <label className={`${lbl} md:col-span-2`}>Vendedor
            <select name="seller_id" defaultValue={c.seller_id ?? ''} className="field mt-1.5">
              <option value="">Sem vendedor</option>
              {sellers.map(s => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          </label>
          <label className={lbl}>Valor bruto (R$)<input name="requested_amount" inputMode="decimal" defaultValue={c.requested} className="field mt-1.5" /></label>
          <label className={lbl}>Valor líquido (R$)<input name="released_amount" inputMode="decimal" defaultValue={c.released} className="field mt-1.5" /></label>
          <label className={lbl}>Parcela (R$)<input name="installment_amount" inputMode="decimal" defaultValue={c.installment} className="field mt-1.5" /></label>
          <label className={lbl}>Prazo (meses)<input name="term" inputMode="numeric" defaultValue={c.term} className="field mt-1.5" /></label>
          <div className={`${lbl} md:col-span-2`}>Nº no banco (ADE)<div className="field mt-1.5 flex items-center bg-surface-muted font-mono">{c.ade ?? '—'}</div></div>
          {editing && <label className={`${lbl} md:col-span-2`}>Motivo{paid ? ' (obrigatório: contrato pago)' : ''}
            <input name="reason" required={paid} minLength={paid ? 3 : undefined} maxLength={2000} placeholder="Ex.: prazo digitado errado" className="field mt-1.5" />
          </label>}
        </fieldset>
        {editing && (
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line px-5 py-3">
            <p className="text-xs text-muted">Salvar recalcula a comissão e fica no histórico (antes → depois).</p>
            <SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Salvar alterações</SubmitButton>
          </div>
        )}
      </form>
    </Card>
  )
}
