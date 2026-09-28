'use client'

import { useState, type ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { findLeadByCpf } from './actions'

const CPF_LIKE = /^\s*\d{3}\.?\d{3}\.?\d{3}-?\d{2}\s*$/

// Board filters (GET form). A CPF typed in the search never goes in the URL: it is sent by POST and the lead opens directly.
export function BoardSearch({ children, className }: { children: ReactNode; className?: string }) {
  const router = useRouter()
  const [notFound, setNotFound] = useState(false)

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    const q = String(new FormData(e.currentTarget).get('q') ?? '')
    setNotFound(false)
    if (!CPF_LIKE.test(q)) return
    e.preventDefault()
    const id = await findLeadByCpf(q)
    if (id) router.push(`/app/crm/leads/${id}`)
    else setNotFound(true)
  }

  return (
    <>
      <form action="/app/crm" onSubmit={onSubmit} role="search" className={className}>{children}</form>
      {notFound && <p role="status" className="mb-4 rounded-[10px] border border-line bg-surface px-4 py-2.5 text-sm text-ink-soft">Nenhum lead seu com este CPF.</p>}
    </>
  )
}
