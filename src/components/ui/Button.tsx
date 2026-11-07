import Link from 'next/link'
import type { ComponentProps } from 'react'
import { cn } from './cn'

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger'
type Size = 'sm' | 'md'

const base = 'inline-flex items-center justify-center gap-2 border-2 font-bold transition-colors disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-highlight focus-visible:ring-offset-1'
const variants: Record<Variant, string> = {
  primary: 'border-ink bg-ink text-canvas hover:bg-ink-soft hover:border-ink-soft',
  secondary: 'border-ink bg-surface text-ink hover:bg-surface-muted',
  ghost: 'border-transparent text-ink hover:underline underline-offset-4',
  danger: 'border-reversed bg-reversed text-white hover:opacity-90',
}
const sizes: Record<Size, string> = { sm: 'h-8 px-3 text-[13px]', md: 'h-10 px-4 text-sm' }

type Common = { variant?: Variant; size?: Size }

export function Button({ variant = 'primary', size = 'md', className, ...props }: Common & ComponentProps<'button'>) {
  return <button className={cn(base, variants[variant], sizes[size], className)} {...props} />
}

export function ButtonLink({ variant = 'primary', size = 'md', className, ...props }: Common & ComponentProps<typeof Link>) {
  return <Link className={cn(base, variants[variant], sizes[size], className)} {...props} />
}
