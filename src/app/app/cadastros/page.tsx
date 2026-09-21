import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canManageTeam } from '@/lib/rbac'

const card = 'block rounded-2xl border border-slate-800 bg-slate-900 p-5 hover:border-emerald-500/40 hover:bg-slate-900/80'

export default async function RegistrationsHubPage() {
  const { membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><h1 className="text-3xl font-semibold">Cadastros</h1><p className="mt-3 text-sm text-slate-400">Área restrita a supervisão, gerência e administração.</p></section>
  const manageTeam = canManageTeam(membership.role)
  const groups = [
    ['Produtos e comercial', [
      ['Instituições / Origens', 'Bancos e instituições usadas na operação.', '/app/comercial/instituicoes'],
      ['Convênios', 'Convênios nacionais habilitados e convênios próprios.', '/app/comercial/convenios'],
      ['Produtos / Tabelas', 'Tabelas comerciais, versões, condições e importação.', '/app/comercial/tabelas'],
      ['Tipos de Contrato', 'Novo, Refinanciamento, Portabilidade, Refin/Portabilidade e tipos próprios.', '/app/comercial/tipos-contrato'],
      ['Empresas de origem de terceiros', 'Masters, promotoras, correspondentes e parceiros externos.', '/app/comercial/origens'],
      ['Grupos de comissão', 'Colunas de repasse como Balcão, Corretores, Parceiros e Indicadores.', '/app/comercial/grupos'],
      ['Regras de comissão', 'À Vista, Diferido, Bônus, Plástico, Seguro e repasses por grupo.', '/app/comercial/regras-comissao'],
      ['Fatores', 'Fatores diários e fixos usados no CRM e nas simulações.', '/app/comercial/fatores'],
      ['Modelo comercial', 'Resumo da configuração comercial da organização.', '/app/comercial'],
    ]],
    ['Rede e acesso', [
      ['Vendedores', 'Consulta, cadastro, acesso, filial, pagamento e identidades bancárias dos vendedores.', '/app/cadastros/vendedores'],
      ['Grupos de vendedores', 'Classificação interna dos vendedores: Básico, Bronze, Prata, Ouro, Diamante ou qualquer outra nomenclatura.', '/app/cadastros/grupos-vendedores'],
      ['Matriz e filiais', 'Unidades usadas para vincular vendedores à estrutura da organização.', '/app/cadastros/filiais'],
      ['Rede comercial', 'Entidades, relações e canais comerciais.', '/app/rede'],
      ...(manageTeam ? [['Equipe e acessos', 'Usuários, papéis e ciclo de acesso.', '/app/equipe']] : []),
    ]],
  ] as const
  return <section>
    <p className="text-sm text-emerald-400">Cadastros</p>
    <h1 className="mt-1 text-3xl font-semibold">Central de cadastros</h1>
    <p className="mt-2 max-w-3xl text-sm text-slate-400">Escolha o assunto que deseja gerenciar. As listas e formulários ficam dentro de cada cadastro, evitando páginas que crescem indefinidamente.</p>
    <div className="mt-7 space-y-8">{groups.map(([label,items]) => <div key={label}><h2 className="text-sm font-semibold uppercase tracking-wide text-slate-400">{label}</h2><div className="mt-3 grid gap-4 md:grid-cols-2 xl:grid-cols-3">{items.map(([title,desc,href]) => <Link key={href} href={href} className={card}><h3 className="font-semibold">{title}</h3><p className="mt-2 text-sm text-slate-400">{desc}</p></Link>)}</div></div>)}</div>
  </section>
}
