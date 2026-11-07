'use client'

import { useState } from 'react'
import { Badge, ButtonLink } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'

export type SignupRow = { id: string; name: string; detail: string; alreadySeller: boolean }

const BULK = 'signup-bulk-reject'
const small = 'h-8 rounded-lg border border-line-strong px-3 text-xs text-ink hover:bg-surface-muted'

// Requests waiting from the registration links (audit 06/11/2026): every refusal asks first, and several can be
// refused at once (a flood from a leaked link is cleared in one step). Refusing erases the data sent; the name stays.
export function SignupQueue({ rows, reject }: { rows: SignupRow[]; reject: (f: FormData) => Promise<void> }) {
  const [marked, setMarked] = useState<Set<string>>(new Set())
  const all = rows.length > 0 && marked.size === rows.length
  const toggle = (id: string) => setMarked(m => { const n = new Set(m); if (n.has(id)) n.delete(id); else n.add(id); return n })
  return (
    <>
      <div className="flex flex-wrap items-center gap-3 border-t border-line px-5 py-2">
        <label className="flex items-center gap-2 text-xs text-ink-soft">
          <input type="checkbox" checked={all} onChange={() => setMarked(all ? new Set() : new Set(rows.map(r => r.id)))} />Marcar todos
        </label>
        <form id={BULK} action={reject} method="post" className="ml-auto"
          onSubmit={e => { if (!marked.size || !window.confirm(`Recusar ${marked.size} cadastro(s)? Os dados enviados serão apagados; ficam só nome e CPF em Recusados.`)) e.preventDefault() }}>
          {[...marked].map(id => <input key={id} type="hidden" name="signup_id" value={id} />)}
          <SubmitButton className={small} pendingText="..." disabled={!marked.size}>Recusar selecionados{marked.size ? ` (${marked.size})` : ''}</SubmitButton>
        </form>
      </div>
      <ul>
        {rows.map(r => (
          <li key={r.id} className="flex flex-wrap items-center gap-3 border-t border-line px-5 py-3">
            <input type="checkbox" aria-label={`Marcar ${r.name}`} checked={marked.has(r.id)} onChange={() => toggle(r.id)} />
            <span className="min-w-0 flex-1">
              <span className="block text-sm font-semibold text-ink">{r.name}</span>
              <span className="block text-[13px] text-ink-soft">{r.detail}</span>
            </span>
            {r.alreadySeller && <Badge tone="pending">Já é vendedor</Badge>}
            <ButtonLink href={`/app/cadastros/vendedores/novo?pedido=${r.id}`} size="sm">Ver e aprovar</ButtonLink>
            <form action={reject} method="post" onSubmit={e => { if (!window.confirm(`Recusar o cadastro de ${r.name}? Os dados enviados serão apagados; ficam só nome e CPF em Recusados.`)) e.preventDefault() }}>
              <input type="hidden" name="signup_id" value={r.id} />
              <SubmitButton className={small} pendingText="...">Recusar</SubmitButton>
            </form>
          </li>
        ))}
      </ul>
    </>
  )
}
