'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Lightbulb } from 'lucide-react'

// "Sugerir melhoria" on every screen; the screen the user was on goes with the request.
export function ImprovementLink({ className }: { className?: string }) {
  const path = usePathname()
  const from = path && path !== '/app/melhorias' ? `?de=${encodeURIComponent(path)}` : ''
  return <Link href={`/app/melhorias${from}`} className={className ?? 'flex items-center gap-2 rounded-lg py-1.5 text-sm text-ink-soft hover:text-ink'}><Lightbulb size={15} aria-hidden />Sugerir melhoria</Link>
}
