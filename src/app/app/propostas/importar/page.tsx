import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { CONTRACT_LAYOUTS } from '@/lib/imports/contract-layout'
import { ContractImportClient } from './ContractImportClient'

export default async function ImportContractsPage() {
  const { access } = await requireAppContext()
  if (!can(access, 'propostas.create') || !can(access, 'clientes.create'))
    return <section><PageHeader title="Importar contratos" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não cadastra contratos e clientes.</Card></section>
  return (
    <section>
      <PageHeader title="Importar contratos"
        description="Suba a planilha de contratos do banco. Cada linha é conferida contra as tabelas, a equipe e os clientes; nada é gravado até você confirmar." />
      <Card className="p-5"><ContractImportClient layouts={CONTRACT_LAYOUTS.map(l => ({ key: l.key, label: l.label }))} /></Card>
    </section>
  )
}
