'use client'

import { Command } from 'cmdk'
import { useRouter } from 'next/navigation'
import { useEffect, useRef, useState, useTransition } from 'react'
import { ArrowRight, FileText, Search, UserRound, Users } from 'lucide-react'
import { Kbd } from '@/components/ui'
import { searchAll, type SearchHit } from '@/app/app/search-actions'
import type { NavItem } from './NavLinks'

const KIND_LABEL: Record<SearchHit['kind'], string> = { client: 'Clientes', proposal: 'Propostas', seller: 'Vendedores' }
const KIND_ICON = { client: UserRound, proposal: FileText, seller: Users }
const GROUP = '[&_[cmdk-group-heading]]:px-3 [&_[cmdk-group-heading]]:py-1.5 [&_[cmdk-group-heading]]:text-xs [&_[cmdk-group-heading]]:font-semibold [&_[cmdk-group-heading]]:text-muted'
const ITEM = 'flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2.5 text-sm text-ink data-[selected=true]:bg-brand-soft'

export function CommandPalette({ nav }: { nav: NavItem[] }) {
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [hits, setHits] = useState<SearchHit[]>([])
  const [pending, startTransition] = useTransition()
  const seq = useRef(0)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        setOpen(o => !o)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // Debounced server search; answers to an older query are dropped.
  useEffect(() => {
    const term = query.trim()
    const id = ++seq.current
    if (term.length < 2) return
    const timer = setTimeout(() => {
      startTransition(async () => {
        const result = await searchAll(term)
        if (id === seq.current) setHits(result)
      })
    }, 250)
    return () => clearTimeout(timer)
  }, [query])

  const go = (href: string) => {
    setOpen(false)
    setQuery('')
    router.push(href)
  }

  const term = query.trim()
  // Results only count for a real query; a cleared input shows the navigation list instead.
  const visible = term.length >= 2 ? hits : []
  const groups = (['client', 'proposal', 'seller'] as const)
    .map(kind => ({ kind, items: visible.filter(h => h.kind === kind) }))
    .filter(g => g.items.length)

  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className="flex h-10 max-w-[520px] flex-1 items-center gap-2.5 rounded-[10px] border border-line bg-surface px-3.5 text-left text-sm text-muted hover:border-line-strong">
        <Search size={16} aria-hidden />
        <span className="flex-1 truncate">Buscar CPF, ADE, cliente ou vendedor</span>
        <span className="hidden sm:inline"><Kbd>Ctrl K</Kbd></span>
      </button>

      <Command.Dialog
        open={open}
        onOpenChange={setOpen}
        label="Busca global"
        shouldFilter={false}
        overlayClassName="fixed inset-0 z-40 bg-black/30"
        contentClassName="fixed left-1/2 top-[12vh] z-50 w-[min(640px,calc(100vw-32px))] -translate-x-1/2 overflow-hidden rounded-[16px] border border-line bg-surface shadow-2xl"
      >
        <div className="flex items-center gap-2.5 border-b border-line px-4">
          <Search size={17} className="text-muted" aria-hidden />
          <Command.Input value={query} onValueChange={setQuery} placeholder="CPF, telefone, nome, ADE ou vendedor" className="h-14 flex-1 bg-transparent text-[15px] text-ink outline-none placeholder:text-muted" />
          {pending ? <span className="text-xs text-muted">buscando…</span> : null}
        </div>
        <Command.List className="max-h-[60vh] overflow-y-auto p-2">
          {term.length >= 2 && !pending && visible.length === 0 ? (
            <div className="px-3 py-8 text-center text-sm text-muted">Nada encontrado para “{term}”.</div>
          ) : null}

          {groups.map(({ kind, items }) => {
            const Icon = KIND_ICON[kind]
            return (
              <Command.Group key={kind} heading={KIND_LABEL[kind]} className={`mb-1 ${GROUP}`}>
                {items.map(h => (
                  <Command.Item key={`${h.kind}-${h.id}`} value={`${h.kind}-${h.id}`} onSelect={() => go(h.href)} className={ITEM}>
                    <Icon size={16} className="shrink-0 text-muted" aria-hidden />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate font-medium">{h.title}</span>
                      {h.subtitle ? <span className="block truncate font-mono text-xs text-muted">{h.subtitle}</span> : null}
                    </span>
                  </Command.Item>
                ))}
              </Command.Group>
            )
          })}

          {term.length < 2 ? (
            <Command.Group heading="Ir para" className={GROUP}>
              {nav.flatMap(n => [
                <Command.Item key={n.key} value={`nav-${n.key}`} onSelect={() => go(n.href)} className={ITEM}>
                  <ArrowRight size={15} className="text-muted" aria-hidden />
                  {n.label}
                </Command.Item>,
                // Sub-entries (Cadastros > Vendedores...): on the phone there is no side menu, so they are reachable here.
                ...(n.children ?? []).map(c => (
                  <Command.Item key={`${n.key}-${c.href}`} value={`nav-${n.key}-${c.href}`} onSelect={() => go(c.href)} className={ITEM}>
                    <ArrowRight size={15} className="text-muted" aria-hidden />
                    <span className="text-muted">{n.label} ›</span> {c.label}
                  </Command.Item>
                )),
              ])}
            </Command.Group>
          ) : null}
        </Command.List>
        <div className="hidden gap-4 border-t border-line px-4 py-2 text-xs text-muted sm:flex">
          <span><Kbd>↑</Kbd> <Kbd>↓</Kbd> navegar</span>
          <span><Kbd>Enter</Kbd> abrir</span>
          <span><Kbd>Esc</Kbd> fechar</span>
        </div>
      </Command.Dialog>
    </>
  )
}
