'use client'

import { useEffect, useState } from 'react'

// Count and total of the entries ticked for "Pagar selecionadas". Each checkbox carries its amount in cents, so the
// sum is integer math.
export function SelectedTotal({ form }: { form: string }) {
  const [sel, setSel] = useState({ n: 0, cents: 0 })
  useEffect(() => {
    const read = () => {
      const boxes = [...document.querySelectorAll<HTMLInputElement>(`input[type=checkbox][form="${form}"]:checked`)]
      setSel({ n: boxes.length, cents: boxes.reduce((s, b) => s + Number(b.dataset.cents ?? 0), 0) })
    }
    document.addEventListener('change', read)
    read()
    return () => document.removeEventListener('change', read)
  }, [form])
  const brl = (sel.cents / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
  return <span className="text-sm text-ink-soft">{sel.n ? `${sel.n} selecionada(s) · ${brl}` : 'Marque as contas na lista para pagar várias de uma vez.'}</span>
}
