'use client'

import { useState, useTransition } from 'react'
import { Search } from 'lucide-react'
import { findDndPhone } from '../actions'

const SOURCE_LABEL: Record<string, string> = { manual: 'marcado à mão', import: 'lista importada', lemit: 'Lemit' }

// Is this phone on the list? Asked by POST: the phone never goes in the address.
export function DndSearch() {
  const [phone, setPhone] = useState('')
  const [answer, setAnswer] = useState<string | null>(null)
  const [pending, start] = useTransition()

  function ask(e: React.FormEvent) {
    e.preventDefault()
    start(async () => {
      const r = await findDndPhone(phone)
      if ('error' in r) setAnswer(r.error)
      else if (!r.found) setAnswer('Este telefone não está na lista.')
      else setAnswer(`Está na lista: ${[SOURCE_LABEL[r.source] ?? r.source, r.fileName, r.note, new Date(r.createdAt).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })].filter(Boolean).join(' · ')}.`)
    })
  }

  return (
    <form method="post" onSubmit={ask} className="grid gap-2 border-b border-line px-5 pb-4 pt-3">
      <div className="flex flex-wrap items-end gap-2">
        <label className="min-w-[200px] flex-1 text-[13px] font-medium text-ink-soft">Conferir um telefone
          <input value={phone} onChange={e => setPhone(e.target.value)} inputMode="tel" placeholder="(68) 99999-0000" className="field mt-1.5" />
        </label>
        <button disabled={pending} className="inline-flex h-10 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted disabled:opacity-60"><Search size={15} aria-hidden />{pending ? 'Conferindo...' : 'Conferir'}</button>
      </div>
      {answer && <p role="status" className="text-sm text-ink">{answer}</p>}
    </form>
  )
}
