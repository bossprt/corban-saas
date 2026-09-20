import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'

const card = 'block rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-emerald-500/40 hover:bg-slate-900/80'

export default async function ReportsHubPage() {
  const { membership } = await requireAppContext()
  const finance = canViewCommission(membership.role)
  const supervisor = atLeast(membership.role, 'supervisor')
  const items = [
    ['Visão geral', 'Indicadores atuais de leads, clientes, propostas e operação.', '/app', true],
    ['Operacional', 'Fila e situação atual da operação.', '/app/operacao', true],
    ['Financeiro e conciliação', 'Comissões, recebimentos comprovados e divergências.', '/app/financeiro', finance],
    ['Central de atenção', 'Pendências e sinais objetivos da organização.', '/app/atencao', supervisor],
  ] as const
  return <section>
    <p className="text-sm text-emerald-400">Relatórios</p>
    <h1 className="mt-1 text-3xl font-semibold">Relatórios e gestão</h1>
    <p className="mt-2 max-w-3xl text-sm text-slate-400">Esta central reúne as visões gerenciais já existentes. Relatórios dedicados de produção, vendas, formalização e comissões serão incorporados aqui sem espalhar novas telas pelo menu principal.</p>
    <div className="mt-6 grid gap-4 md:grid-cols-2">{items.filter(i => i[3]).map(([title,desc,href]) => <Link key={href} href={href} className={card}><h2 className="font-semibold">{title}</h2><p className="mt-2 text-sm text-slate-400">{desc}</p></Link>)}</div>
  </section>
}
