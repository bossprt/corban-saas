import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { REQUIRED_STAGE_STATES, missingStages } from '@/lib/catalog'
import { addChecklistItem, createChecklist, createDefaultStages, createRoute, createTable, createVersion, publishChecklist, publishVersion } from './actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const VSTATUS: Record<string, string> = { draft: 'Rascunho', published: 'Publicada', superseded: 'Substituída', expired: 'Expirada' }
const num = (v: number | string | null) => (v === null ? '—' : String(v))

export default async function CatalogPage() {
  const { supabase, membership } = await requireAppContext()
  const canCatalog = atLeast(membership.role, 'manager')
  const canChecklist = atLeast(membership.role, 'supervisor')
  const [banks, providers, agreements, products, modalities, docTypes, routes, tables, versions, templates, items, stages] = await Promise.all([
    supabase.from('banks').select('id,name').order('name'), supabase.from('providers').select('id,name').order('name'),
    supabase.from('agreements').select('id,bank_id,name').order('name'), supabase.from('products').select('id,name').order('name'),
    supabase.from('modalities').select('id,product_id,name').order('name'), supabase.from('document_types').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_product_routes').select('id,bank_id,provider_id,agreement_id,product_id,modality_id,status').not('bank_id', 'is', null).order('created_at', { ascending: false }),
    supabase.from('product_tables').select('id,route_id,code,name,status').order('name'),
    supabase.from('product_table_versions').select('id,product_table_id,version,status,rate,coefficient,term_min,term_max').order('version', { ascending: false }),
    supabase.from('document_checklist_templates').select('id,route_id,version,status,name').order('version', { ascending: false }),
    supabase.from('document_checklist_items').select('id,template_id,document_type_id,label,is_required,sort_order').order('sort_order'),
    supabase.from('operational_stages').select('canonical_state,is_active'),
  ])
  const name = (rows: { id: string; name: string }[] | null) => new Map((rows ?? []).map(r => [r.id, r.name]))
  const bankN = name(banks.data), provN = name(providers.data), agrN = name(agreements.data), prodN = name(products.data), modN = name(modalities.data), docN = name(docTypes.data)
  const routeLabel = (r: { bank_id: string; agreement_id: string; product_id: string; modality_id: string }) => `${bankN.get(r.bank_id) ?? 'Banco'} · ${agrN.get(r.agreement_id) ?? 'Convênio'} · ${prodN.get(r.product_id) ?? 'Produto'} · ${modN.get(r.modality_id) ?? 'Tipo de Contrato'}`
  const routeName = new Map((routes.data ?? []).map(r => [r.id, routeLabel(r)]))
  const referenceReady = !!(banks.data?.length && providers.data?.length && agreements.data?.length && products.data?.length && modalities.data?.length)
  const activeStageStates = (stages.data ?? []).filter(s => s.is_active).map(s => s.canonical_state)
  const stagesMissing = missingStages(activeStageStates)

  return <section>
    <h1 className="text-3xl font-semibold">Catálogo comercial</h1>
    <p className="mt-2 text-sm text-slate-400">Rotas, tabelas, checklist de documentos e etapas da operação da sua organização. Isto é o <strong>cadastro comercial</strong> usado nas simulações; não liga nenhum banco automaticamente.</p>
    <p className="mt-3 rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-3 text-sm text-emerald-200">Novo: cadastre bancos, convênios (governos e prefeituras), tabelas, prazos, coeficientes e grupos de comissão em <a href="/app/comercial" className="underline">Modelo comercial</a>. Esta tela mostra o catálogo anterior (rotas por produto e modalidade), que continua funcionando.</p>
    {!canCatalog && <p className="mt-3 rounded-xl border border-slate-800 p-3 text-xs text-slate-400">Seu perfil só consulta o catálogo{canChecklist ? ' e edita checklists' : ''}. Rotas, tabelas e etapas são de gerente/administrador.</p>}
    {!referenceReady && <p role="alert" className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-amber-200">O catálogo de referência (bancos, convênios, produtos, tipos de contrato, tipos de documento) ainda não foi carregado pelo administrador da plataforma. Sem ele não é possível criar rotas nem checklists.</p>}

    <h2 className="mt-8 text-xl font-semibold">1. Etapas da operação</h2>
    <div className={`${card} mt-3 text-sm`}>
      {stagesMissing.length === 0 ? <p className="text-emerald-300">Todas as etapas da operação existem ({REQUIRED_STAGE_STATES.length}).</p> : <>
        <p className="text-amber-200">Faltam {stagesMissing.length} etapa(s): {stagesMissing.map(s => s.name).join(', ')}. Sem elas não é possível enviar propostas para a operação.</p>
        {canCatalog && <form action={createDefaultStages} className="mt-3"><SubmitButton className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950" pendingText="Criando...">Criar etapas padrão</SubmitButton><p className="mt-2 text-xs text-slate-500">Cria só as que faltam, sem prazo (SLA) definido. O prazo é decisão da organização.</p></form>}</>}
    </div>

    <h2 className="mt-8 text-xl font-semibold">2. Rotas comerciais</h2>
    <div className={`${card} mt-3`}>
      {!routes.data?.length ? <p className="text-sm text-slate-400">Nenhuma rota ainda. Uma rota combina banco, provedor, convênio, produto e tipo de contrato.</p> : <ul className="space-y-1 text-sm">{routes.data.map(r => <li key={r.id}>{routeLabel(r)} <span className="text-xs text-slate-500">· {provN.get(r.provider_id) ?? 'Provedor'} · {r.status === 'active' ? 'ativa' : 'inativa'}</span></li>)}</ul>}
      {canCatalog && referenceReady && <form action={createRoute} className="mt-4 grid gap-2 md:grid-cols-3">
        <select required name="bank_id" defaultValue="" className={field}><option value="" disabled>Banco</option>{banks.data?.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <select required name="provider_id" defaultValue="" className={field}><option value="" disabled>Provedor / master</option>{providers.data?.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <select required name="agreement_id" defaultValue="" className={field}><option value="" disabled>Convênio</option>{agreements.data?.map(a => <option key={a.id} value={a.id}>{bankN.get(a.bank_id) ?? 'Banco'} — {a.name}</option>)}</select>
        <select required name="product_id" defaultValue="" className={field}><option value="" disabled>Produto</option>{products.data?.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <select required name="modality_id" defaultValue="" className={field}><option value="" disabled>Tipo de Contrato</option>{modalities.data?.map(m => <option key={m.id} value={m.id}>{prodN.get(m.product_id) ?? 'Produto'} — {m.name}</option>)}</select>
        <SubmitButton className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Criar rota</SubmitButton>
      </form>}
    </div>

    <h2 className="mt-8 text-xl font-semibold">3. Tabelas e versões</h2>
    <div className="mt-3 space-y-3">
      {!tables.data?.length && <p className={`${card} text-sm text-slate-400`}>Nenhuma tabela ainda. Crie uma tabela para uma rota e depois uma versão com taxa/coeficiente.</p>}
      {tables.data?.map(t => <div key={t.id} className={card}>
        <div className="font-medium">{t.name} <span className="text-xs text-slate-500">· {t.code} · {routeName.get(t.route_id) ?? 'rota'}</span></div>
        <div className="mt-2 space-y-1 text-sm">{(versions.data ?? []).filter(v => v.product_table_id === t.id).map(v => <div key={v.id} className="flex flex-wrap items-center gap-3">
          <span>v{v.version} · {VSTATUS[v.status] ?? v.status} · taxa {num(v.rate)} · coeficiente {num(v.coefficient)} · prazo {num(v.term_min)}–{num(v.term_max)}</span>
          {v.status === 'draft' && canCatalog && <form action={publishVersion}><input type="hidden" name="version_id" value={v.id} /><SubmitButton className="rounded border border-emerald-500/60 px-2 py-1 text-xs text-emerald-300" pendingText="Publicando...">Publicar</SubmitButton></form>}
        </div>)}</div>
        {canCatalog && <form action={createVersion} className="mt-3 grid gap-2 md:grid-cols-5"><input type="hidden" name="table_id" value={t.id} />
          <input name="rate" inputMode="decimal" placeholder="Taxa (%)" className={field} /><input name="coefficient" inputMode="decimal" placeholder="Coeficiente" className={field} />
          <input name="term_min" inputMode="numeric" placeholder="Prazo mín." className={field} /><input name="term_max" inputMode="numeric" placeholder="Prazo máx." className={field} />
          <SubmitButton className="rounded-lg border border-slate-700 px-3 py-2 text-sm">Nova versão (rascunho)</SubmitButton></form>}
      </div>)}
      {canCatalog && !!routes.data?.length && <form action={createTable} className={`${card} grid gap-2 md:grid-cols-4`}>
        <select required name="route_id" defaultValue="" className={`${field} md:col-span-2`}><option value="" disabled>Rota da tabela</option>{routes.data.map(r => <option key={r.id} value={r.id}>{routeLabel(r)}</option>)}</select>
        <input required name="code" placeholder="Código (ex.: TAB-01)" maxLength={40} className={field} /><input required name="name" placeholder="Nome da tabela" maxLength={120} className={field} />
        <SubmitButton className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950 md:col-span-4 md:justify-self-end">Criar tabela</SubmitButton>
        <p className="text-xs text-slate-500 md:col-span-4">A simulação usa a versão PUBLICADA: valor × coeficiente = parcela. Sem coeficiente a parcela aparece como &ldquo;Não calculado&rdquo;. Nada é preenchido por padrão.</p>
      </form>}
    </div>

    <h2 className="mt-8 text-xl font-semibold">4. Checklist de documentos</h2>
    <div className="mt-3 space-y-3">
      {!templates.data?.length && <p className={`${card} text-sm text-slate-400`}>Nenhum checklist ainda. Crie um por rota, adicione os documentos exigidos e publique.</p>}
      {templates.data?.map(t => <div key={t.id} className={card}>
        <div className="font-medium">{t.name} <span className="text-xs text-slate-500">· v{t.version} · {t.status === 'draft' ? 'Rascunho' : t.status === 'published' ? 'Publicado' : 'Substituído'} · {routeName.get(t.route_id) ?? 'rota'}</span></div>
        <ul className="mt-2 list-disc pl-5 text-sm text-slate-300">{(items.data ?? []).filter(i => i.template_id === t.id).map(i => <li key={i.id}>{i.label} <span className="text-xs text-slate-500">· {docN.get(i.document_type_id) ?? 'tipo'} · {i.is_required ? 'obrigatório' : 'opcional'}</span></li>)}</ul>
        {t.status === 'draft' && canChecklist && <div className="mt-3 space-y-2">
          <form action={addChecklistItem} className="grid gap-2 md:grid-cols-4"><input type="hidden" name="template_id" value={t.id} />
            <select required name="document_type_id" defaultValue="" className={field}><option value="" disabled>Tipo de documento</option>{docTypes.data?.map(d => <option key={d.id} value={d.id}>{d.name}</option>)}</select>
            <input required name="label" placeholder="Como o operador vê (ex.: RG ou CNH)" maxLength={120} className={field} />
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_required" defaultChecked /> Obrigatório</label>
            <SubmitButton className="rounded-lg border border-slate-700 px-3 py-2 text-sm">Adicionar</SubmitButton></form>
          <form action={publishChecklist}><input type="hidden" name="template_id" value={t.id} /><SubmitButton className="rounded border border-emerald-500/60 px-3 py-1.5 text-xs text-emerald-300" pendingText="Publicando...">Publicar checklist</SubmitButton></form>
        </div>}
      </div>)}
      {canChecklist && !!routes.data?.length && <form action={createChecklist} className={`${card} grid gap-2 md:grid-cols-4`}>
        <select required name="route_id" defaultValue="" className={`${field} md:col-span-2`}><option value="" disabled>Rota do checklist</option>{routes.data.map(r => <option key={r.id} value={r.id}>{routeLabel(r)}</option>)}</select>
        <input required name="name" placeholder="Nome do checklist" maxLength={120} className={field} />
        <SubmitButton className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Criar checklist</SubmitButton></form>}
    </div>
  </section>
}
