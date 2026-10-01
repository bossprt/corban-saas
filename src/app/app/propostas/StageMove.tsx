'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { feedbackUrl } from '@/lib/feedback'
import { moveToStage } from './stage-actions'

export type StageOption = { id: string; name: string; canonical_state: string }
type Pending = { caseId: string; proposalId: string; stage: StageOption; onDone?: (ok: boolean) => void }

const todayBr = () => new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 10)

// One flow for every place a proposal changes stage. "Paga" asks the day it was paid (today already filled in);
// "Pendência" offers a note and a due date, both optional. Every other stage moves at once.
export function useStageMove() {
  const router = useRouter()
  const [pending, setPending] = useState<Pending | null>(null)
  const [busy, start] = useTransition()

  const run = (p: Pending, extra: { note?: string; pendencyDue?: string; paidOn?: string }) => start(async () => {
    const code = await moveToStage({ caseId: p.caseId, stageId: p.stage.id, proposalId: p.proposalId, ...extra })
    setPending(null)
    p.onDone?.(code.startsWith('ok:'))
    // The page's own feedback banner (?f=), as every other action: it stays visible even when the row leaves the list.
    const url = new URL(window.location.href)
    url.searchParams.delete('f')
    router.replace(feedbackUrl(url.pathname + url.search, code), { scroll: false })
  })

  const move = (p: Pending) => {
    if (p.stage.canonical_state === 'paid' || p.stage.canonical_state === 'pending_external') setPending(p)
    else run(p, {})
  }

  const cancel = () => { pending?.onDone?.(false); setPending(null) }

  const ui = (
    <>
      {pending && <StageDialog key={pending.caseId + pending.stage.id} pending={pending} busy={busy} onCancel={cancel} onConfirm={extra => run(pending, extra)} />}
    </>
  )
  return { move, busy, ui }
}

function StageDialog({ pending, busy, onCancel, onConfirm }: { pending: Pending; busy: boolean; onCancel: () => void; onConfirm: (extra: { note?: string; pendencyDue?: string; paidOn?: string }) => void }) {
  const paid = pending.stage.canonical_state === 'paid'
  const [paidOn, setPaidOn] = useState(todayBr())
  const [note, setNote] = useState('')
  const [due, setDue] = useState('')
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" onClick={onCancel}>
      <form role="dialog" aria-modal="true" aria-label={`Mover para ${pending.stage.name}`} onClick={e => e.stopPropagation()}
        onSubmit={e => { e.preventDefault(); onConfirm(paid ? { paidOn, note } : { note, pendencyDue: due }) }}
        className="w-full max-w-sm space-y-3 rounded-[14px] bg-surface p-5 text-sm shadow-xl">
        <h2 className="text-base font-semibold text-ink">Mover para {pending.stage.name}</h2>
        {paid ? (
          <label className="block text-[13px] font-medium text-ink-soft">Pago ao cliente em
            <input type="date" required max={todayBr()} value={paidOn} onChange={e => setPaidOn(e.target.value)} className="field mt-1.5" />
          </label>
        ) : (
          <label className="block text-[13px] font-medium text-ink-soft">Prazo da pendência (opcional)
            <input type="date" value={due} onChange={e => setDue(e.target.value)} className="field mt-1.5" />
          </label>
        )}
        <label className="block text-[13px] font-medium text-ink-soft">Observação (opcional)
          <input maxLength={500} value={note} onChange={e => setNote(e.target.value)} className="field mt-1.5" />
        </label>
        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onCancel} className="h-10 rounded-[10px] border border-line px-4 font-medium text-ink-soft hover:bg-surface-muted">Cancelar</button>
          <button disabled={busy} className="h-10 rounded-[10px] bg-brand px-4 font-semibold text-white hover:bg-brand-strong disabled:opacity-60">Confirmar</button>
        </div>
      </form>
    </div>
  )
}

// A stage list with "Salvar": the table rows and the contract page.
export function StageSelect({ caseId, proposalId, stages, currentStageId, label = 'Etapa', compact = false }: {
  caseId: string; proposalId: string; stages: StageOption[]; currentStageId: string; label?: string; compact?: boolean
}) {
  const [value, setValue] = useState(currentStageId)
  const { move, busy, ui } = useStageMove()
  const target = stages.find(s => s.id === value)
  const changed = value !== currentStageId && !!target
  return (
    <div className={compact ? '' : 'space-y-2'}>
      {ui}
      <div className="flex items-center gap-2">
        <select aria-label={label} value={value} onChange={e => setValue(e.target.value)} className={`field ${compact ? 'h-8 py-0 text-[13px]' : ''}`}>
          {stages.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
        </select>
        <button type="button" disabled={!changed || busy}
          onClick={() => target && move({ caseId, proposalId, stage: target, onDone: ok => { if (!ok) setValue(currentStageId) } })}
          className={`shrink-0 rounded-[10px] bg-brand px-3 font-semibold text-white hover:bg-brand-strong disabled:opacity-40 ${compact ? 'h-8 text-xs' : 'h-10 text-sm'}`}>
          Salvar
        </button>
      </div>
    </div>
  )
}
