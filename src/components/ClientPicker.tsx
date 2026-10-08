'use client'

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { Search, X } from 'lucide-react'
import { searchClients } from '@/app/app/search-actions'

type Hit = { id: string; name: string; cpf: string | null }

// Client field of the forms: type a name or CPF, pick one. The search runs by POST (server action), so a CPF never
// goes in a URL; the form receives only the client's id in a hidden input. Works for any number of clients.
// optional: the form may be sent without a client (e.g. the simulator: the client is needed only to save).
export function ClientPicker({ name, initial, label = 'Cliente', optional = false }: { name: string; initial?: Hit | null; label?: string; optional?: boolean }) {
  const [chosen, setChosen] = useState<Hit | null>(initial ?? null)
  const [q, setQ] = useState('')
  const [hits, setHits] = useState<Hit[]>([])
  const [searched, setSearched] = useState(false)
  const seq = useRef(0)

  useEffect(() => {
    if (chosen || q.trim().length < 2) return
    const n = ++seq.current
    const t = setTimeout(async () => {
      const r = await searchClients(q)
      if (n === seq.current) { setHits(r); setSearched(true) }
    }, 250)
    return () => clearTimeout(t)
  }, [q, chosen])

  if (chosen) {
    return (
      <div className="mt-1.5 flex h-10 items-center justify-between gap-2 rounded-[10px] border border-line bg-surface-muted/60 px-3 text-sm">
        <input type="hidden" name={name} value={chosen.id} />
        <span className="truncate text-ink"><span className="font-medium">{chosen.name}</span>{chosen.cpf && <span className="ml-2 font-mono text-[13px] text-muted">{chosen.cpf}</span>}</span>
        <button type="button" onClick={() => { setChosen(null); setQ(''); setHits([]); setSearched(false) }} aria-label="Trocar cliente" className="inline-flex size-7 items-center justify-center rounded-md text-muted hover:bg-surface hover:text-ink"><X size={15} aria-hidden /></button>
      </div>
    )
  }

  const typed = q.trim().length >= 2
  return (
    <div className="relative mt-1.5">
      {/* Keeps the form from submitting without a client: the browser flags this required, empty field. */}
      {!optional && <input tabIndex={-1} aria-hidden required value="" onChange={() => {}} name={`${name}__required`} className="pointer-events-none absolute inset-0 opacity-0" />}
      <label className="flex h-10 items-center gap-2 rounded-[10px] border border-line bg-surface px-3 focus-within:border-brand">
        <Search size={15} className="text-muted" aria-hidden />
        <input value={q} onChange={e => { setQ(e.target.value); setSearched(false) }} placeholder="Nome ou CPF do cliente" aria-label={label} autoComplete="off" className="h-full flex-1 bg-transparent text-sm text-ink outline-none placeholder:text-muted" />
      </label>
      {typed && (hits.length > 0 || searched) && (
        <ul role="listbox" className="absolute z-20 mt-1 max-h-72 w-full overflow-auto rounded-[10px] border border-line bg-surface py-1 shadow-lg">
          {hits.map(h => (
            <li key={h.id}>
              <button type="button" role="option" aria-selected={false} onClick={() => setChosen(h)} className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left text-sm hover:bg-surface-muted">
                <span className="truncate text-ink">{h.name}</span>{h.cpf && <span className="font-mono text-[12px] text-muted">{h.cpf}</span>}
              </button>
            </li>
          ))}
          {searched && !hits.length && (
            <li className="flex items-center justify-between gap-3 px-3 py-2 text-sm text-muted">
              Nenhum cliente encontrado.
              <Link href="/app/clientes?novo=1" className="font-medium text-brand hover:underline">Cadastrar novo cliente</Link>
            </li>
          )}
        </ul>
      )}
    </div>
  )
}
