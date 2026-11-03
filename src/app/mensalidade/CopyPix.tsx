'use client'
import { useState } from 'react'

// Pix "copia e cola": the code in a read-only field and a button that copies it.
export function CopyPix({ code }: { code: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <div className="mt-3 flex gap-2">
      <input readOnly value={code} aria-label="Pix copia e cola" onFocus={e => e.currentTarget.select()} className="field min-w-0 flex-1 font-mono text-xs" />
      <button type="button" onClick={async () => { try { await navigator.clipboard.writeText(code); setCopied(true) } catch { setCopied(false) } }}
        className="h-10 shrink-0 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">
        {copied ? 'Copiado' : 'Copiar código'}
      </button>
    </div>
  )
}
