'use client'

import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useState, useTransition } from 'react'
import { RefreshCw } from 'lucide-react'
import type { RecalcResult } from './actions'

// The row checkboxes live in the table (form="recalc-form"); this bar marks them and sends the chosen ones.
export function RecalcBar({ action }: { action: (f: FormData) => Promise<RecalcResult> }) {
  const router = useRouter()
  const [result, setResult] = useState<RecalcResult | null>(null)
  const [count, setCount] = useState(0)
  const [pending, start] = useTransition()
  const boxes = () => Array.from(document.querySelectorAll<HTMLInputElement>('input[form="recalc-form"][name="ids"]'))
  const mark = (pick: (b: HTMLInputElement) => boolean) => { boxes().forEach(b => { b.checked = pick(b) }); setCount(boxes().filter(b => b.checked).length) }
  const submit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    const data = new FormData(e.currentTarget)
    setResult(null)
    start(async () => {
      const r = await action(data)
      setResult(r)
      if (!r.error) { mark(() => false); router.refresh() }
    })
  }
  const btn = 'inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted'
  return (
    <form id="recalc-form" onSubmit={submit} onChange={() => setCount(boxes().filter(b => b.checked).length)} className="grid gap-2 border-b border-line px-5 py-3">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="text-ink-soft">{count ? `${count} marcado(s)` : 'Marque os contratos para recalcular a comissão'}</span>
        <button type="button" onClick={() => mark(() => true)} className={btn}>Marcar todos desta página</button>
        <button type="button" onClick={() => mark(b => b.dataset.stale === '1')} className={btn}>Marcar desatualizados</button>
        {count > 0 && <button type="button" onClick={() => mark(() => false)} className={btn}>Desmarcar</button>}
        <button type="submit" disabled={pending || !count} aria-busy={pending} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">
          <RefreshCw size={15} aria-hidden className={pending ? 'animate-spin' : ''} />{pending ? 'Recalculando...' : 'Recalcular selecionados'}
        </button>
      </div>
      {result && (
        <div role="status" className={`rounded-[10px] border px-3 py-2 text-sm ${result.error || result.failed.length ? 'border-[#FCD34D] bg-[#FFFBEB] text-[#92400E]' : 'border-[#86EFAC] bg-[#F0FDF4] text-[#166534]'}`}>
          {result.error ?? `${result.ok} contrato(s) recalculado(s).${result.failed.length ? ` ${result.failed.length} não puderam ser recalculados:` : ''}`}
          {!!result.failed.length && <ul className="mt-1 list-disc pl-5">{result.failed.map(x => <li key={x.id}><Link href={`/app/propostas/${x.id}`} className="underline">{x.label}</Link>: {x.reason}</li>)}</ul>}
        </div>
      )}
    </form>
  )
}
