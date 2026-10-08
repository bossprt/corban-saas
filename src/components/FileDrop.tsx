'use client'
import { useRef, useState } from 'react'
import { FileSpreadsheet, FileText, Upload } from 'lucide-react'

// A file field that looks like one: a dashed box with a button, drag and drop, and the chosen file names.
// The real <input type="file" name=...> covers the box (invisible): click and drop land on it natively, and the browser's
// "required" message still has a field to point at. Works in server-action forms and client forms alike.
// compact: one line, for a file field inside a table row or a short form.
export function FileDrop({ name, accept, multiple, required, hint, buttonLabel, ariaLabel, compact, onChange }: {
  name?: string; accept: string; multiple?: boolean; required?: boolean; hint?: string; buttonLabel?: string; ariaLabel?: string; compact?: boolean
  onChange?: (files: File[]) => void
}) {
  const input = useRef<HTMLInputElement>(null)
  const [names, setNames] = useState<string[]>([])
  const changed = () => {
    const files = Array.from(input.current?.files ?? [])
    setNames(files.map(f => f.name))
    onChange?.(files)
  }
  const Icon = /pdf|image/.test(accept) ? FileText : FileSpreadsheet
  const button = buttonLabel ?? (multiple ? 'Escolher arquivos do computador' : 'Escolher arquivo do computador')
  const field = <input ref={input} type="file" name={name} accept={accept} multiple={multiple} required={required} aria-label={ariaLabel ?? button} className="absolute inset-0 h-full w-full cursor-pointer opacity-0" onChange={changed} />
  if (compact) return (
    <label className="relative flex min-w-0 flex-1 cursor-pointer items-center gap-2 rounded-[10px] border-2 border-dashed border-line-strong bg-surface-muted/50 px-2 py-1.5 text-xs text-ink-soft hover:border-brand hover:bg-surface-muted">
      <span className="inline-flex shrink-0 items-center gap-1 rounded-md bg-brand px-2 py-1 font-semibold text-white"><Upload size={13} aria-hidden />{buttonLabel ?? (multiple ? 'Escolher arquivos' : 'Escolher arquivo')}</span>
      <span className={`truncate ${names.length ? 'font-medium text-ink' : 'text-muted'}`}>{names.length ? names.join(', ') : (hint ?? 'ou arraste aqui')}</span>
      {field}
    </label>
  )
  return (
    <label
      className="relative flex cursor-pointer flex-col items-center justify-center gap-2 rounded-[12px] border-2 border-dashed border-line-strong bg-surface-muted/50 px-4 py-6 text-center text-sm text-ink-soft hover:border-brand hover:bg-surface-muted"
    >
      <Icon size={24} className="text-brand" aria-hidden />
      <span className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white"><Upload size={16} aria-hidden />{button}</span>
      <span>{multiple ? 'ou arraste os arquivos aqui' : 'ou arraste o arquivo aqui'}{hint ? ` (${hint})` : ''}</span>
      {names.length > 0
        ? <span className="text-xs font-medium text-ink">{names.length > 1 ? `${names.length} arquivos: ` : 'Arquivo: '}{names.join(', ')}</span>
        : <span className="text-xs text-muted">Nenhum arquivo escolhido</span>}
      {field}
    </label>
  )
}
