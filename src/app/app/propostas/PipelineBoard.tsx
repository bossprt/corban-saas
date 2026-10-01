'use client'

import { useState } from 'react'
import Link from 'next/link'
import { DndContext, PointerSensor, TouchSensor, KeyboardSensor, useDraggable, useDroppable, useSensor, useSensors, type DragEndEvent } from '@dnd-kit/core'
import { useStageMove, type StageOption } from './StageMove'

// A drop ends with a click on the card's link; that click must not open the contract.
let lastDrop = 0

export type BoardCard = { caseId: string; proposalId: string; stageId: string; name: string; sub: string; amount: string; days: number; alert: string }
export type BoardColumn = StageOption & { code: string; closed: boolean }

// Kanban of the pipeline: drag a card to any column. Closed columns (Paga, Recusada, Cancelada) show the last 7 days.
export function PipelineBoard({ columns, cards: initial, canEdit }: { columns: BoardColumn[]; cards: BoardCard[]; canEdit: boolean }) {
  const [cards, setCards] = useState(initial)
  const [synced, setSynced] = useState(initial)
  // New data from the server (after a move or a refresh) replaces the local copy.
  if (synced !== initial) { setSynced(initial); setCards(initial) }
  const { move, ui } = useStageMove()
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 6 } }),
    useSensor(KeyboardSensor),
  )

  const onDragEnd = (e: DragEndEvent) => {
    lastDrop = Date.now()
    const card = cards.find(c => c.caseId === e.active.id)
    const stage = columns.find(s => s.id === e.over?.id)
    if (!card || !stage || stage.id === card.stageId) return
    const before = cards
    setCards(cs => cs.map(c => (c.caseId === card.caseId ? { ...c, stageId: stage.id, days: 0, alert: '' } : c)))
    move({ caseId: card.caseId, proposalId: card.proposalId, stage, onDone: ok => { if (!ok) setCards(before) } })
  }

  return (
    <>
      {ui}
      <DndContext sensors={sensors} onDragEnd={onDragEnd}>
        <div className="flex gap-3 overflow-x-auto pb-2" aria-label="Kanban da esteira">
          {columns.map(st => <Column key={st.id} column={st} cards={cards.filter(c => c.stageId === st.id)} canEdit={canEdit} />)}
        </div>
      </DndContext>
    </>
  )
}

function Column({ column, cards, canEdit }: { column: BoardColumn; cards: BoardCard[]; canEdit: boolean }) {
  const { setNodeRef, isOver } = useDroppable({ id: column.id, disabled: !canEdit })
  return (
    <section ref={setNodeRef} aria-label={column.name}
      className={`flex min-w-[10.5rem] flex-1 basis-0 flex-col rounded-[14px] border bg-surface-muted ${isOver ? 'border-brand ring-2 ring-brand/30' : 'border-line'}`}>
      <header className="flex items-center justify-between px-3 py-2.5 text-sm font-semibold text-ink">{column.name}<span className="num text-xs font-normal text-muted">{cards.length}</span></header>
      <div className="flex min-h-24 flex-col gap-2 px-2 pb-2">
        {cards.map(c => <Card key={c.caseId} card={c} canEdit={canEdit} />)}
        {cards.length === 0 && <p className="px-1 py-3 text-center text-xs text-muted">{canEdit ? 'Arraste para cá' : 'Vazio'}</p>}
        {column.closed && <Link href={`/app/propostas?etapa=${column.code}`} className="px-1 pt-1 text-center text-xs text-brand hover:text-brand-strong">Últimos 7 dias · ver todas</Link>}
      </div>
    </section>
  )
}

function Card({ card, canEdit }: { card: BoardCard; canEdit: boolean }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: card.caseId, disabled: !canEdit })
  const style = transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined
  return (
    <div ref={setNodeRef} style={style} {...attributes} {...listeners} aria-roledescription="cartão arrastável"
      className={`touch-manipulation rounded-[10px] border border-line bg-surface text-[13px] ${isDragging ? 'z-10 cursor-grabbing shadow-lg' : canEdit ? 'cursor-grab hover:border-brand/50' : 'hover:border-brand/50'}`}>
      <Link href={`/app/propostas/${card.proposalId}`} draggable={false} onClick={e => { if (Date.now() - lastDrop < 400) e.preventDefault() }} className="block p-3">
        <span className="block font-medium text-ink">{card.name}</span>
        <span className="mt-0.5 block text-xs text-muted">{card.sub}</span>
        <span className="mt-2 flex items-center justify-between">
          <span className="num font-semibold text-ink">{card.amount}</span>
          <span className={`num text-xs ${card.days >= 4 ? 'font-semibold text-diverged' : 'text-muted'}`}>{card.days === 0 ? 'hoje' : `${card.days} d`}</span>
        </span>
        {card.alert && <span className="mt-1.5 block text-xs font-medium text-diverged">{card.alert}</span>}
      </Link>
    </div>
  )
}
