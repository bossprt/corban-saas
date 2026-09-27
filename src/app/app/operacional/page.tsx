import Link from 'next/link'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

export default async function OperationalHubPage() {
  const { membership } = await requireAppContext()
  const supervisor = atLeast(membership.role, 'supervisor')
  const items = [
    ['Esteira operacional', 'Casos, filas, movimentações e acompanhamento da operação.', '/app/operacao', true],
    ['Propostas / contratos', 'Consultar propostas e abrir o detalhe operacional.', '/app/propostas', true],
    ['Documentos', 'Documentos, conferência e pendências documentais.', '/app/documentos', true],
    ['Central de atenção', 'Pendências objetivas, SLA e itens que precisam de ação.', '/app/atencao', supervisor],
  ] as const
  return <section>
    <PageHeader title="Backoffice e formalização" description="A área operacional organiza o trabalho que a equipe executa." />
    <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
      {items.filter(i => i[3]).map(([title, desc, href]) => (
        <Link key={href} href={href} className="block">
          <Card className="p-5 hover:bg-surface-muted">
            <h2 className="font-semibold text-ink">{title}</h2>
            <p className="mt-2 text-sm text-muted">{desc}</p>
          </Card>
        </Link>
      ))}
    </div>
  </section>
}
