import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

const card = 'block rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-emerald-500/40 hover:bg-slate-900/80'

export default async function OperationalHubPage() {
  const { membership } = await requireAppContext()
  const supervisor = atLeast(membership.role, 'supervisor')
  const items = [
    ['Esteira operacional', 'Casos, filas, movimentações e acompanhamento da operação.', '/app/operacao', true],
    ['Propostas / contratos', 'Consultar propostas e abrir o detalhe operacional.', '/app/propostas', true],
    ['Documentos', 'Documentos, conferência e pendências documentais.', '/app/documentos', true],
    ['Importações', 'Produção, evidências, lotes e arquivos recebidos de parceiros.', '/app/importacoes', supervisor],
    ['Central de atenção', 'Pendências objetivas, SLA e itens que precisam de ação.', '/app/atencao', supervisor],
    ['Integrações', 'Execuções, falhas e comunicação com sistemas externos.', '/app/integracoes', supervisor],
  ] as const
  return <section>
    <p className="text-sm text-emerald-400">Operacional</p>
    <h1 className="mt-1 text-3xl font-semibold">Backoffice, formalização e importações</h1>
    <p className="mt-2 max-w-3xl text-sm text-slate-400">A área operacional organiza o trabalho que a equipe executa. Importação e integração aparecem como atividades da operação, não como cadastros escondidos.</p>
    <div className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-3">{items.filter(i => i[3]).map(([title,desc,href]) => <Link key={href} href={href} className={card}><h2 className="font-semibold">{title}</h2><p className="mt-2 text-sm text-slate-400">{desc}</p></Link>)}</div>
  </section>
}
