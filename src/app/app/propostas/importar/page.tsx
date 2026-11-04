import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { CONTRACT_LAYOUTS } from '@/lib/imports/contract-layout'
import { ContractImportClient } from './ContractImportClient'

// The Bevicred layout reads one import day per call, from every credential of the company.
export const maxDuration = 120

export default async function ImportContractsPage({ searchParams }: { searchParams: Promise<{ bevicred?: string }> }) {
  const { access } = await requireAppContext()
  const auto = (await searchParams).bevicred === '1'
  if (!can(access, 'propostas.create') || !can(access, 'clientes.create'))
    return <section><PageHeader title="Importar contratos" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não cadastra contratos e clientes.</Card></section>
  return (
    <section>
      <PageHeader title="Importar contratos"
        description="Traga os contratos do banco: planilha, relatório em PDF ou busca na Bevicred. Cada linha é conferida contra as tabelas, a equipe e os clientes; nada é gravado até você confirmar." />
      <Card className="p-5"><ContractImportClient layouts={CONTRACT_LAYOUTS.map(l => ({ key: l.key, label: l.label, pdf: !!l.pdf, api: !!l.api }))} autoBevicred={auto} /></Card>
    </section>
  )
}
