'use client'

import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { CalendarClock } from 'lucide-react'
import { MANUAL_STAGES, STAGE_LABEL, type LeadStage } from '@/lib/crm'
import { moveLeadOnBoard } from './actions'

export type BoardCard = {
  id: string
  name: string
  status: LeadStage
  campaign: string | null
  owner: string | null
  nextContact: string | null   // ISO
  overdue: boolean
  isClient: boolean
}
export type BoardColumn = { stage: LeadStage; cards: BoardCard[]; total: number }

const ACCENT: Record<LeadStage, string> = {
  new: 'bg-[#94A3B8]', contacted: 'bg-[#F59E0B]', negotiating: 'bg-[#6366F1]', proposal: 'bg-brand', won: 'bg-[#16A34A]', lost: 'bg-[#DC2626]',
}
// A card can be dropped only on the stages a seller moves by hand ("lost" asks for a reason on the lead page).
const DROPPABLE = new Set<LeadStage>(MANUAL_STAGES.filter(s => s !== 'lost'))

const when = (iso: string) => new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' })

export function Board({ columns, showOwner }: { columns: BoardColumn[]; showOwner: boolean }) {
  const router = useRouter()
  const [dragging, setDragging] = useState<BoardCard | null>(null)
  const [over, setOver] = useState<LeadStage | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [pending, start] = useTransition()

  function drop(stage: LeadStage) {
    const card = dragging
    setOver(null); setDragging(null)
    if (!card || card.status === stage) return
    if (!DROPPABLE.has(stage) || !DROPPABLE.has(card.status)) {
      setMessage(stage === 'lost' ? 'Para marcar como perdido, abra o lead e informe o motivo.' : 'Proposta e Ganho seguem a proposta do cliente: não se movem à mão.')
      return
    }
    start(async () => {
      const r = await moveLeadOnBoard(card.id, stage)
      setMessage(r.ok ? null : r.message)
      router.refresh()
    })
  }

  return (
    <div>
      {message && <p role="alert" className="mb-3 rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-2.5 text-sm text-[#92400E]">{message}</p>}
      <div className="-mx-4 overflow-x-auto px-4 pb-2 md:mx-0 md:px-0" aria-busy={pending}>
        <div className="grid min-w-[900px] grid-cols-6 gap-2.5">
          {columns.map(col => (
            <section
              key={col.stage}
              aria-label={`${STAGE_LABEL[col.stage]}: ${col.total}`}
              onDragOver={e => { if (dragging) { e.preventDefault(); setOver(col.stage) } }}
              onDragLeave={() => setOver(o => (o === col.stage ? null : o))}
              onDrop={e => { e.preventDefault(); drop(col.stage) }}
              className={`flex min-h-[320px] min-w-0 flex-col rounded-[12px] border bg-surface-muted/60 p-2 transition-colors ${over === col.stage ? (DROPPABLE.has(col.stage) ? 'border-brand bg-brand/5' : 'border-[#DC2626]/40') : 'border-line'}`}
            >
              <header className="mb-2 flex items-center gap-2 px-1.5 pt-1">
                <span className={`size-2 rounded-full ${ACCENT[col.stage]}`} aria-hidden />
                <h2 className="text-[13px] font-semibold text-ink">{STAGE_LABEL[col.stage]}</h2>
                <span className="num ml-auto text-xs text-muted">{col.total}</span>
              </header>
              <ul className="grid min-w-0 gap-2">
                {col.cards.map(c => (
                  <li
                    key={c.id}
                    draggable
                    onDragStart={e => { setDragging(c); e.dataTransfer.effectAllowed = 'move' }}
                    onDragEnd={() => { setDragging(null); setOver(null) }}
                    className={`min-w-0 overflow-hidden rounded-[10px] border border-line bg-surface shadow-sm transition-opacity ${dragging?.id === c.id ? 'opacity-50' : ''}`}
                  >
                    <Link href={`/app/crm/leads/${c.id}`} title={c.name} className="block min-w-0 px-3 py-2.5 hover:bg-surface-muted/60">
                      <span className="line-clamp-2 break-words text-sm font-medium leading-snug text-ink">{c.name}</span>
                      {c.campaign && <span className="block truncate text-xs text-muted">{c.campaign}</span>}
                      <span className="mt-1.5 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs">
                        {c.nextContact && (
                          <span className={`inline-flex items-center gap-1 ${c.overdue ? 'font-semibold text-[#B91C1C]' : 'text-ink-soft'}`}>
                            <CalendarClock size={12} aria-hidden />{c.overdue ? 'Atrasado · ' : ''}{when(c.nextContact)}
                          </span>
                        )}
                        {c.isClient && <span className="rounded bg-brand/10 px-1.5 py-px font-medium text-brand">Cliente</span>}
                        {showOwner && <span className="block min-w-0 max-w-full truncate text-muted">{c.owner ?? 'Sem vendedor'}</span>}
                      </span>
                    </Link>
                  </li>
                ))}
                {col.total > col.cards.length && <li className="px-2 py-1 text-xs text-muted">+ {col.total - col.cards.length} (use os filtros)</li>}
                {col.total === 0 && <li className="px-2 py-6 text-center text-xs text-muted">Nenhum lead</li>}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </div>
  )
}
