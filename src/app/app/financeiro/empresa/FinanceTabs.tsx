import Link from 'next/link'

const TABS = [
  { href: '/app/financeiro/empresa', label: 'Contas a pagar e receber' },
  { href: '/app/financeiro/empresa/extrato', label: 'Extrato bancário' },
  { href: '/app/financeiro/empresa/relatorios', label: 'Fluxo de caixa e DRE' },
  { href: '/app/financeiro/empresa/a-lancar', label: 'Comissões e repasses a lançar' },
  { href: '/app/financeiro/empresa/contas', label: 'Contas bancárias' },
  { href: '/app/financeiro/empresa/plano', label: 'Plano de contas' },
]

// The company finance pages share this row of tabs.
export function FinanceTabs({ current }: { current: string }) {
  return (
    <nav aria-label="Financeiro da empresa" className="mb-5 flex flex-wrap gap-1.5">
      {TABS.map(t => (
        <Link key={t.href} href={t.href} aria-current={t.href === current ? 'page' : undefined}
          className={`rounded-[10px] border px-3 py-1.5 text-sm ${t.href === current ? 'border-brand bg-brand text-white' : 'border-line bg-surface text-ink-soft hover:bg-surface-muted'}`}>
          {t.label}
        </Link>
      ))}
    </nav>
  )
}
