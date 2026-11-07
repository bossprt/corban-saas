import type { ComponentProps, ReactNode } from 'react'
import { cn } from './cn'

// A section of the page, not a box: a thick black rule on top, no frame, no rounded corners (identity "Boleto ipê").
export function Card({ className, ...props }: ComponentProps<'section'>) {
  return <section className={cn('border-t-[3px] border-ink bg-surface', className)} {...props} />
}

export function CardHeader({ title, action, className }: { title: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={cn('flex items-baseline justify-between gap-3 pt-4', className)}>
      <h2 className="wide text-lg font-extrabold text-ink">{title}</h2>
      {action}
    </div>
  )
}

export function CardBody({ className, ...props }: ComponentProps<'div'>) {
  return <div className={cn('py-4', className)} {...props} />
}
