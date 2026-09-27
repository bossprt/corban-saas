import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { PageHeader } from '@/components/ui'

const card = 'block rounded-[14px] border border-line bg-surface p-5 hover:border-brand hover:bg-surface-muted'

export default async function CrmHubPage() {
  await requireAppContext()
  const items = [
    ['Clientes', 'Pesquisar, cadastrar e abrir a visão 360 do cliente.', '/app/clientes'],
    ['Leads', 'Acompanhar entradas, qualificação e próximos contatos.', '/app/leads'],
    ['Simulações', 'Simular condições comerciais publicadas para o cliente.', '/app/simulacoes'],
    ['Propostas', 'Acompanhar propostas vinculadas aos clientes e à operação.', '/app/propostas'],
  ] as const
  return <section>
    <p className="text-sm font-medium text-brand">CRM</p>
    <PageHeader title="Relacionamento e oportunidades" description="Aqui fica o trabalho comercial do dia a dia. Configurações de base, campanhas e automações do SmartMatch entram nesta área conforme forem integradas." />
    <div className="grid gap-4 md:grid-cols-2">{items.map(([title,desc,href]) => <Link key={href} href={href} className={card}><h2 className="font-semibold text-ink">{title}</h2><p className="mt-2 text-sm text-muted">{desc}</p></Link>)}</div>
  </section>
}
