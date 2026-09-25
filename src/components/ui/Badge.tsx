import type { ReactNode } from 'react'
import { cn } from './cn'

export type Tone = 'neutral' | 'brand' | 'received' | 'diverged' | 'reversed' | 'paid-out' | 'pending' | 'expected'

const tones: Record<Tone, string> = {
  neutral: 'bg-[#F1F0EC] text-ink-soft',
  brand: 'bg-brand-soft text-brand-strong',
  received: 'bg-[#DCEFE6] text-[#064E3B]',
  diverged: 'bg-[#FEF3C7] text-[#92400E]',
  reversed: 'bg-[#FDE2E1] text-[#991B1B]',
  'paid-out': 'bg-[#E8EEF7] text-[#1E3A8A]',
  pending: 'bg-[#EDE9FE] text-[#5B21B6]',
  expected: 'bg-[#EEF0F3] text-[#3B4656]',
}

export function Badge({ tone = 'neutral', children, className }: { tone?: Tone; children: ReactNode; className?: string }) {
  return <span className={cn('inline-flex items-center rounded-md px-2 py-0.5 text-xs font-semibold', tones[tone], className)}>{children}</span>
}
