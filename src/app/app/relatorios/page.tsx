import Link from 'next/link'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

export default async function ReportsHubPage() {
  const { membership } = await requireAppContext()
  const supervisor = atLeast(membership.role, 'supervisor')
  const items = [
    ['Visão geral', 'Indicadores atuais de leads, clientes, propostas e operação.', '/app', true],
    ['Operacional', 'Fila e situação atual da operação.', '/app/operacao', true],
    ['Central de atenção', 'Pendências e sinais objetivos da organização.', '/app/atencao', supervisor],
  ] as const
  return <section>
    <PageHeader
      title="Relatórios e gestão"
      description="Esta central reúne as visões gerenciais já existentes. Relatórios dedicados de produção, vendas, formalização e comissões serão incorporados aqui sem espalhar novas telas pelo menu principal."
    />
    <div className="grid gap-4 md:grid-cols-2">
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
