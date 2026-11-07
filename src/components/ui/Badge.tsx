import type { ReactNode } from 'react'
import { cn } from './cn'

export type Tone = 'neutral' | 'brand' | 'received' | 'diverged' | 'reversed' | 'paid-out' | 'pending' | 'expected'

const tones: Record<Tone, string> = {
  neutral: 'bg-surface-muted text-ink-soft',
  brand: 'bg-highlight text-ink',
  received: 'bg-[#DCEFE6] text-[#064E3B]',
  diverged: 'bg-[#FFEDD5] text-[#9A3412]',
  reversed: 'bg-[#FDE2E1] text-[#9F0D24]',
  'paid-out': 'bg-[#E8EEF7] text-[#1E3A8A]',
  pending: 'bg-[#EDE9FE] text-[#5B21B6]',
  expected: 'bg-[#EEF0F3] text-[#3B4656]',
}

export function Badge({ tone = 'neutral', children, className }: { tone?: Tone; children: ReactNode; className?: string }) {
  return <span className={cn('inline-flex items-center rounded-md px-2 py-0.5 text-xs font-semibold', tones[tone], className)}>{children}</span>
}
