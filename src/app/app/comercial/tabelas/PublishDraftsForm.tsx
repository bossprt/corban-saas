'use client'
import { useState } from 'react'
import { SubmitButton } from '@/components/SubmitButton'
import { publishDrafts } from './actions'

const dateBr = (d: string) => d.split('-').reverse().join('/')

// "Publicar todas": every draft found by the current filters, one start date, after a confirmation.
export function PublishDraftsForm({ ids, defaultDate, back }: { ids: string[]; defaultDate: string; back: string }) {
  const [date, setDate] = useState(defaultDate)
  const n = ids.length
  return (
    <form action={publishDrafts} method="post" className="flex flex-wrap items-end gap-2"
      onSubmit={e => { if (!date || !window.confirm(`Publicar ${n} tabela(s) a partir de ${dateBr(date)}? Os contratos a partir dessa data passam a usar estas comissões.`)) e.preventDefault() }}>
      <input type="hidden" name="back" value={back} />
      {ids.map(id => <input key={id} type="hidden" name="version_id" value={id} />)}
      <label className="text-xs font-medium text-[#92400E]">Início da vigência
        <input type="date" name="effective_from" required min="2000-01-01" value={date} onChange={e => setDate(e.target.value)} className="field mt-1 block h-9 w-40 py-0 text-sm" /></label>
      <SubmitButton className="h-9 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Publicando...">Publicar todas ({n})</SubmitButton>
    </form>
  )
}
