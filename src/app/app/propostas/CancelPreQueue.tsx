'use client'
import { useState } from 'react'
import { SubmitButton } from '@/components/SubmitButton'
import { cancelBeforeQueue } from './[id]/actions'

const ghost = 'inline-flex h-8 items-center whitespace-nowrap rounded-[10px] border border-line bg-surface px-3 text-xs font-medium hover:bg-surface-muted'

// Cancel with the proposal spelled out right under its card (owner, 08/10/2026: scrolling to a far column lost the
// client's name and left him unsure of what he was cancelling).
export function CancelPreQueue({ proposalId, summary }: { proposalId: string; summary: React.ReactNode }) {
  const [open, setOpen] = useState(false)
  if (!open) return <button type="button" onClick={() => setOpen(true)} className={`${ghost} text-[#B91C1C]`}>Cancelar</button>
  return (
    <form action={cancelBeforeQueue} className="mt-3 grid w-full gap-2 rounded-[10px] border border-[#F5C2C2] bg-[#FDECEC] p-3 text-sm text-[#7F1D1D]">
      <input type="hidden" name="proposal_id" value={proposalId} /><input type="hidden" name="back" value="/app/propostas" />
      <p>{summary}</p>
      <label className="text-[13px] font-medium">Motivo do cancelamento
        <input name="reason" required minLength={3} maxLength={300} autoFocus placeholder="Ex.: era teste, cliente desistiu" className="field mt-1.5" />
      </label>
      <div className="flex flex-wrap gap-2">
        <SubmitButton className="inline-flex h-9 items-center rounded-[10px] bg-[#B91C1C] px-4 text-sm font-semibold text-white hover:bg-[#991B1B]" pendingText="Cancelando...">Sim, cancelar</SubmitButton>
        <button type="button" onClick={() => setOpen(false)} className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-4 text-sm text-ink hover:bg-surface-muted">Voltar</button>
      </div>
      <span className="text-xs">A proposta não é apagada: fica cancelada no histórico, com o motivo, e o lead volta para Negociando.</span>
    </form>
  )
}
