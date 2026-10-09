'use client'

import { useState, type ReactNode } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { findClientByCpf } from '@/app/app/search-actions'

const CPF_LIKE = /^\s*\d{3}\.?\d{3}\.?\d{3}-?\d{2}\s*$/

// A list filter (GET form) that also takes a CPF. A CPF must not travel in a URL, so when the search box holds one the
// form does not submit: the CPF goes by POST to findClientByCpf and the screen opens by the client's id instead.
// mode "client" opens the client file; mode "filter" keeps the other filters and adds cliente=<id>.
export function CpfSearchForm({ action, mode, className, children }: { action: string; mode: 'client' | 'filter'; className?: string; children: ReactNode }) {
  const router = useRouter()
  const [notFound, setNotFound] = useState(false)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    const form = e.currentTarget
    const q = String(new FormData(form).get('q') ?? '')
    setNotFound(false)
    if (!CPF_LIKE.test(q)) return
    e.preventDefault()
    setBusy(true)
    try {
      const hit = await findClientByCpf(q)
      if (!hit) { setNotFound(true); return }
      if (mode === 'client') { router.push(`/app/clientes/${hit.id}`); return }
      const params = new URLSearchParams()
      for (const [k, v] of new FormData(form)) if (k !== 'q' && typeof v === 'string' && v !== '') params.set(k, v)
      params.set('cliente', hit.id)
      router.push(`${action}?${params.toString()}`)
    } finally { setBusy(false) }
  }

  return (
    <>
      <form action={action} method="get" onSubmit={onSubmit} className={className} role="search" aria-busy={busy}>{children}</form>
      {notFound && (
        <div role="status" className="mb-4 flex flex-wrap items-center gap-3 rounded-[10px] border border-line bg-surface px-4 py-3 text-sm text-ink-soft">
          Nenhum cliente com este CPF.
          <Link href="/app/clientes?novo=1" className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-sm font-medium text-white hover:bg-brand-strong">Cadastrar novo cliente</Link>
        </div>
      )}
    </>
  )
}
