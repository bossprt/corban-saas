import type { ComponentProps, ReactNode } from 'react'
import { cn } from './cn'

export function Card({ className, ...props }: ComponentProps<'section'>) {
  return <section className={cn('rounded-[14px] border border-line bg-surface', className)} {...props} />
}

export function CardHeader({ title, action, className }: { title: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={cn('flex items-center justify-between gap-3 px-5 pt-5', className)}>
      <h2 className="text-base font-semibold text-ink">{title}</h2>
      {action}
    </div>
  )
}

export function CardBody({ className, ...props }: ComponentProps<'div'>) {
  return <div className={cn('p-5', className)} {...props} />
}
