import { PageHeader } from '@/components/ui'
import { SavedSimulations } from './SavedSimulations'
import { SimulatorPanel, type SimulatorSp } from './SimulatorPanel'

export default async function SimulationsPage({ searchParams }: { searchParams: Promise<SimulatorSp> }) {
  const sp = await searchParams
  return (
    <section>
      <PageHeader title="Simulações" description="Escolha o convênio e simule por valor ou por parcela: o Corban compara todas as tabelas que têm fator e mostra a melhor primeiro." />
      <SimulatorPanel sp={sp} />
      <SavedSimulations />
    </section>
  )
}
