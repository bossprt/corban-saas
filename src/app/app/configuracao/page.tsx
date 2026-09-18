import { requireAppContext } from '@/lib/appContext'

export default async function ConfigurationPage() {
  const { supabase, membership } = await requireAppContext()
  const [banks, routes, tables, versions, types, checklists, stages] = await Promise.all([
    supabase.from('banks').select('*', { count: 'exact', head: true }),
    supabase.from('organization_product_routes').select('*', { count: 'exact', head: true }).eq('status','active'),
    supabase.from('product_tables').select('*', { count: 'exact', head: true }).eq('status','active'),
    supabase.from('product_table_versions').select('*', { count: 'exact', head: true }).eq('status','published'),
    supabase.from('document_types').select('*', { count: 'exact', head: true }).eq('is_active',true),
    supabase.from('document_checklist_templates').select('*', { count: 'exact', head: true }).eq('status','published'),
    supabase.from('operational_stages').select('*', { count: 'exact', head: true }).eq('is_active',true),
  ])
  const items = [
    ['Bancos', banks.count ?? 0, 'Catálogo global'],
    ['Rotas', routes.count ?? 0, 'Banco/convênio/produto/modalidade do tenant'],
    ['Tabelas', tables.count ?? 0, 'Tabela comercial ativa'],
    ['Versões publicadas', versions.count ?? 0, 'Necessária para simular'],
    ['Tipos de documento', types.count ?? 0, 'Vocabulário documental'],
    ['Checklists publicados', checklists.count ?? 0, 'Necessário para preparar proposta'],
    ['Etapas operacionais', stages.count ?? 0, 'Necessário para enviar à mesa'],
  ] as const

  return <section>
    <h1 className="text-3xl font-semibold">Prontidão do tenant</h1>
    <p className="mt-2 text-sm text-slate-400">Diagnóstico determinístico do que falta para executar o Vertical Slice sem inventar dados comerciais.</p>
    <div className="mt-6 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
      {items.map(([name,count,description]) => <div key={name} className="rounded-xl border border-slate-800 bg-slate-900 p-5">
        <div className="flex items-center justify-between"><h2 className="font-medium">{name}</h2><span className={count > 0 ? 'text-emerald-400' : 'text-amber-400'}>{count > 0 ? 'OK' : 'Pendente'}</span></div>
        <div className="mt-3 text-2xl font-semibold">{count}</div><p className="mt-1 text-xs text-slate-500">{description}</p>
      </div>)}
    </div>
    <div className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5 text-sm text-slate-300">
      Perfil atual: <strong>{membership.role}</strong>. Dados de taxa, coeficiente, comissão, convênio e tabela não são preenchidos automaticamente: precisam vir de fonte comercial válida.
    </div>
  </section>
}
