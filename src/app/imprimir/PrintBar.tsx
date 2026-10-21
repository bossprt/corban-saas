'use client'

import Link from 'next/link'
import { Printer } from 'lucide-react'

// Bar above the printed sheets: print (the browser's "save as PDF" too) and back. Never printed itself.
export function PrintBar({ back, children }: { back: string; children?: React.ReactNode }) {
  return (
    <div className="print-hide mx-auto mb-4 flex max-w-[210mm] flex-wrap items-center gap-2">
      <Link href={back} className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted">Voltar</Link>
      {children}
      <button type="button" onClick={() => window.print()} className="ml-auto inline-flex h-9 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">
        <Printer size={15} aria-hidden />Imprimir / salvar PDF
      </button>
    </div>
  )
}
