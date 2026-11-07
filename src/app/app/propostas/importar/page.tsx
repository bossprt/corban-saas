import { Card, PageHeader } from '@/components/ui'
import { canImportBevicred, canImportContracts } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { listBevicredCredentials } from '@/lib/bevicred.server'
import { layoutsFor } from '@/lib/imports/contract-layout'
import { ContractImportClient } from './ContractImportClient'

// The Bevicred layout reads one import day per call, from every credential of the company.
export const maxDuration = 120

export default async function ImportContractsPage({ searchParams }: { searchParams: Promise<{ bevicred?: string }> }) {
  const { supabase, access, organization } = await requireAppContext()
  const auto = (await searchParams).bevicred === '1' && canImportBevicred(access)
  if (!canImportContracts(access))
    return <section><PageHeader title="Importar contratos" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não importa contratos. Peça ao administrador.</Card></section>
  const bevicred = canImportBevicred(access)
  const [{ data: banks }, { data: providers }, credentials] = await Promise.all([
    supabase.from('organization_banks').select('name').eq('is_active', true),
    supabase.from('organization_providers').select('name').eq('is_active', true),
    bevicred ? listBevicredCredentials(organization.id).catch(() => []) : Promise.resolve([]),
  ])
  const layouts = layoutsFor((banks ?? []).map(b => b.name), credentials.length > 0, (providers ?? []).map(p => p.name))
  return (
    <section>
      <PageHeader title="Importar contratos"
        description="Traga os contratos do banco ou da promotora: planilha, relatório em PDF ou busca na Bevicred. Cada linha é conferida contra as tabelas, a equipe e os clientes; nada é gravado até você confirmar." />
      {layouts.length === 0
        ? <Card className="p-5 text-sm text-ink-soft">Nenhum layout de importação serve para os bancos da empresa.</Card>
        : <Card className="p-5"><ContractImportClient layouts={layouts.map(l => ({ key: l.key, label: l.label, pdf: !!l.pdf, api: !!l.api, model: !l.provider }))} autoBevicred={auto} /></Card>}
    </section>
  )
}
