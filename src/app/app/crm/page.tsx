import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'

const card = 'block rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-emerald-500/40 hover:bg-slate-900/80'

export default async function CrmHubPage() {
  await requireAppContext()
  const items = [
    ['Clientes', 'Pesquisar, cadastrar e abrir a visão 360 do cliente.', '/app/clientes'],
    ['Leads', 'Acompanhar entradas, qualificação e próximos contatos.', '/app/leads'],
    ['Simulações', 'Simular condições comerciais publicadas para o cliente.', '/app/simulacoes'],
    ['Propostas', 'Acompanhar propostas vinculadas aos clientes e à operação.', '/app/propostas'],
  ] as const
  return <section>
    <p className="text-sm text-emerald-400">CRM</p>
    <h1 className="mt-1 text-3xl font-semibold">Relacionamento e oportunidades</h1>
    <p className="mt-2 max-w-3xl text-sm text-slate-400">Aqui fica o trabalho comercial do dia a dia. Configurações de base, campanhas e automações do SmartMatch entram nesta área conforme forem integradas.</p>
    <div className="mt-6 grid gap-4 md:grid-cols-2">{items.map(([title,desc,href]) => <Link key={href} href={href} className={card}><h2 className="font-semibold">{title}</h2><p className="mt-2 text-sm text-slate-400">{desc}</p></Link>)}</div>
  </section>
}
