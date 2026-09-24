import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { ReceiptImportClient } from './ReceiptImportClient'

export default async function ImportReceiptPage() {
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'financeiro.edit')) return <section><PageHeader title="Importar relatório" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não importa relatórios de comissão.</Card></section>
  const [{ data: banks }, { data: providers }] = await Promise.all([
    supabase.from('organization_banks').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_providers').select('id,name').eq('is_active', true).order('name'),
  ])
  const sources = [...(banks ?? []).map(b => ({ value: `bank:${b.id}`, label: `${b.name} · banco` })), ...(providers ?? []).map(p => ({ value: `provider:${p.id}`, label: `${p.name} · promotora` }))]
  return (
    <section>
      <PageHeader title="Importar relatório de comissão" description="O relatório entra em conferência: cada linha é comparada, ao centavo, com a comissão calculada na proposta. Nada é lançado até você confirmar." />
      <Card className="p-5"><ReceiptImportClient sources={sources} /></Card>
    </section>
  )
}
