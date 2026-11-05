'use client'
import { useState } from 'react'
import { Copy } from 'lucide-react'

// The registration link in a read-only field and a button that copies it.
export function CopyLink({ url, label }: { url: string; label: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <div className="flex min-w-0 flex-1 gap-2">
      <input readOnly value={url} aria-label={`Link de cadastro ${label}`} onFocus={e => e.currentTarget.select()} className="field h-9 min-w-0 flex-1 font-mono text-xs" />
      <button type="button" onClick={async () => { try { await navigator.clipboard.writeText(url); setCopied(true) } catch { setCopied(false) } }}
        className="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong">
        <Copy size={14} aria-hidden />{copied ? 'Copiado' : 'Copiar'}
      </button>
    </div>
  )
}
