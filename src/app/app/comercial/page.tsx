import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { onboardingSteps } from '@/lib/commercial'
import { savePayoutPolicy } from './actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'
type Group = { id: string; name: string; calculation_basis: string }
export default async function CommercialPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  const seeCommission = canViewCommission(membership.role)
  if (!atLeast(membership.role, 'supervisor')) return <section><h1 className="text-3xl font-semibold">Modelo comercial</h1>
    <p role="alert" className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-300">O modelo comercial é restrito a supervisor, gerente e administrador.</p></section>

  const [banks, providers, agreements, groups, routes, tables, versions, conditions, polRows, polVersions, polItems] = await Promise.all([
    supabase.from('organization_banks').select('id,name,is_active').order('name'),
    supabase.from('organization_providers').select('id,name,is_active').order('name'),
    supabase.from('organization_agreements').select('id,name,is_active').order('name'),
    supabase.from('commission_groups').select('id,name,calculation_basis,is_active').order('sort_order').order('name'),
    supabase.from('organization_product_routes').select('id').not('org_bank_id', 'is', null),
    supabase.from('product_tables').select('id,route_id,status').order('name'),
    supabase.from('product_table_versions').select('id,product_table_id,status').order('version', { ascending: false }),
    supabase.from('commercial_conditions').select('id,product_table_version_id'),
    supabase.from('payout_policies').select('id,name,is_active').order('name'),
    supabase.from('payout_policy_versions').select('id,policy_id,version,base_kind,discount_pct').order('version', { ascending: false }),
    supabase.from('payout_policy_items').select('version_id,group_id,pct'),
  ])
  const groupN = new Map((groups.data ?? []).map(g => [g.id, g.name]))
  const activeGroups = (groups.data ?? []).filter(g => g.is_active) as Group[]
  const routeIds = new Set((routes.data ?? []).map(r => r.id))
  const v3Tables = (tables.data ?? []).filter(t => routeIds.has(t.route_id))
  const receivedGroups = activeGroups.filter(g => g.calculation_basis === 'percent_of_received_commission')
  const policies = (polRows.data ?? []).map(p => {
    const latest = (polVersions.data ?? []).find(v => v.policy_id === p.id)
    return { ...p, latest, items: latest ? (polItems.data ?? []).filter(i => i.version_id === latest.id) : [] }
  })

  const publishedCount = (versions.data ?? []).filter(v => v.status === 'published').length
  const draftIds = new Set((versions.data ?? []).filter(v => v.status === 'draft').map(v => v.id))
  const onboarding = onboardingSteps({ banks: (banks.data ?? []).length, agreements: (agreements.data ?? []).length, groups: (groups.data ?? []).length, tables: v3Tables.length, draftConditions: (conditions.data ?? []).filter(c => draftIds.has(c.product_table_version_id)).length, publishedVersions: publishedCount })

  return <section>
    <h1 className="text-3xl font-semibold">Modelo comercial</h1>
    <p className="mt-2 text-sm text-slate-400">Instituição/Origem → Convênio → Tabela → Tipo de Contrato → Prazo → Coeficiente/Taxa → Comissão recebida → Comissão dos grupos. Os códigos técnicos ficam por conta do sistema.</p>
    {!canEdit && <p className="mt-3 rounded-xl border border-slate-800 p-3 text-xs text-slate-400">Seu perfil só consulta. Cadastros e condições são de gerente/administrador.</p>}

    <nav aria-label="Passo a passo" className={`${card} mt-4`}>
      <div className="flex items-center justify-between text-sm"><strong>Passo a passo</strong><span className="text-slate-400">{onboarding.steps.filter(s => s.done).length} de {onboarding.steps.length}</span></div>
      <ol className="mt-3 grid gap-2 md:grid-cols-3">{onboarding.steps.map((s, n) => <li key={s.key}><a href={`#${s.anchor}`} className={`block rounded-lg border p-3 text-sm ${s.done ? 'border-emerald-500/30 text-emerald-300' : s === onboarding.next ? 'border-amber-500/50 text-amber-200' : 'border-slate-800 text-slate-400'}`}>
        <span className="font-medium">{s.done ? '✓' : n + 1}. {s.label}</span><span className="mt-1 block text-xs opacity-80">{s.done ? 'Pronto' : s.hint}</span></a></li>)}</ol>
      {onboarding.next ? <p className="mt-3 text-xs text-amber-200">Próximo: {onboarding.next.label}.</p> : <p className="mt-3 text-xs text-emerald-300">Tudo pronto: as simulações já usam a versão publicada.</p>}
    </nav>

    <h2 id="passo-bancos" className="mt-8 scroll-mt-4 text-xl font-semibold">1. Cadastros-base</h2>
    <div className="mt-3 grid gap-3 md:grid-cols-2">
      <div className={card}>
        <div className="flex items-start justify-between gap-3"><div><strong>Instituições / Origens</strong><p className="mt-1 text-xs text-slate-500">Banco ou instituição que está no lado de origem da operação, como Daycoval, NASP ou Hope.</p></div><span className="rounded-full border border-slate-700 px-2 py-1 text-xs text-slate-300">{(banks.data ?? []).filter(b => b.is_active).length} ativas</span></div>
        <div className="mt-4 flex gap-2"><Link href="/app/comercial/instituicoes" className={btn}>Gerenciar</Link></div>
      </div>
      <div className={card}>
        <div className="flex items-start justify-between gap-3"><div><strong>Empresas de origem de terceiros</strong><p className="mt-1 text-xs text-slate-500">Usadas somente quando a tabela/produção vem de uma empresa externa.</p></div><span className="rounded-full border border-slate-700 px-2 py-1 text-xs text-slate-300">{(providers.data ?? []).filter(p => p.is_active).length} ativas</span></div>
        <div className="mt-4 flex gap-2"><Link href="/app/comercial/origens" className={ghost}>Gerenciar</Link></div>
      </div>
    </div>

    <h2 id="passo-convenios" className="mt-8 scroll-mt-4 text-xl font-semibold">2. Convênios</h2>
    <div className={`${card} mt-3`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><strong>{(agreements.data ?? []).filter(a => a.is_active).length} convênio(s) ativo(s)</strong><p className="mt-1 text-xs text-slate-500">Cadastre próprios ou habilite governos e prefeituras da base nacional em uma tela separada.</p></div>
        <Link href="/app/comercial/convenios" className={btn}>Gerenciar convênios</Link>
      </div>
    </div>

    {seeCommission ? <><h2 id="passo-grupos" className="mt-8 scroll-mt-4 text-xl font-semibold">3. Grupos e regras de comissão</h2>
    <div className={`${card} mt-3 space-y-4 text-sm`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><strong>{activeGroups.length} grupo(s) ativo(s)</strong><p className="mt-1 text-xs text-slate-500">O grupo identifica quem recebe. Você só precisa informar o nome e como o percentual deve ser interpretado.</p></div>
        <Link href="/app/comercial/grupos" className={btn}>Gerenciar grupos</Link>
      </div>
      <div className="rounded-xl border border-slate-800 bg-slate-950/40 p-4">
        <strong>Regra padrão de comissão <span className="font-normal text-slate-500">(opcional)</span></strong>
        <p className="mt-1 text-xs text-slate-400">Serve para não repetir o mesmo percentual em todas as linhas. Exemplo: se a empresa recebe 10% e o grupo Corretores recebe 65% da comissão recebida, o resultado efetivo é 6,5% da produção.</p>
        {!policies.length ? <p className="mt-3 text-xs text-slate-500">Nenhuma regra padrão cadastrada. Você pode informar os percentuais diretamente em cada condição ou na planilha.</p> : <ul className="mt-3 space-y-1">{policies.map(p => <li key={p.id}><strong>{p.name}</strong> <span className="text-xs text-slate-500">· v{p.latest?.version ?? '—'} · {p.latest?.base_kind === 'net' ? `base líquida (desconto ${p.latest.discount_pct}%)` : 'base bruta'}{!p.is_active ? ' · inativa' : ''} · {(p.items ?? []).map(i => `${groupN.get(i.group_id) ?? 'grupo'} ${i.pct}%`).join(', ') || 'sem grupos'}</span></li>)}</ul>}
        {canEdit && (receivedGroups.length ? <details className="mt-4"><summary className="cursor-pointer text-sm font-medium text-emerald-300">Criar ou atualizar regra padrão</summary><form action={savePayoutPolicy} className="mt-3 grid gap-2 md:grid-cols-4">
          <select name="policy_id" defaultValue="" className={`${field} md:col-span-2`}><option value="">Nova regra padrão</option>{policies.filter(p => p.is_active).map(p => <option key={p.id} value={p.id}>Nova versão de: {p.name}</option>)}</select>
          <input name="name" maxLength={80} placeholder="Nome da regra (ex.: Padrão Corretores)" className={`${field} md:col-span-2`} />
          <select name="base_kind" defaultValue="gross" className={field}><option value="gross">Usar comissão recebida bruta</option><option value="net">Usar comissão líquida após desconto</option></select>
          <input name="discount" inputMode="decimal" placeholder="Desconto (%) se usar líquida" className={field} />
          {receivedGroups.map(g => <label key={g.id} className="text-xs text-slate-400">{g.name}<input name={`p_${g.id}`} inputMode="decimal" placeholder="% da comissão recebida" className={`${field} mt-1 w-full`} /></label>)}
          <SubmitButton className={`${btn} md:col-span-4 md:justify-self-end`} pendingText="Salvando...">Salvar regra padrão</SubmitButton>
        </form></details> : <p className="mt-3 text-xs text-amber-200">Para usar regra padrão, crie ao menos um grupo configurado como percentual da comissão recebida.</p>)}
      </div>
    </div></> : <div className={`${card} mt-8 text-sm text-slate-400`}>As regras financeiras de comissão não estão disponíveis para este perfil.</div>}

    <h2 id="passo-tabelas" className="mt-8 scroll-mt-4 text-xl font-semibold">4. Tabelas e condições</h2>
    <div className={`${card} mt-3`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><strong>{v3Tables.length} tabela(s) cadastrada(s)</strong><p className="mt-1 text-xs text-slate-500">Crie tabelas, importe condições em massa por CSV/XLSX, edite rascunhos e publique versões na área própria.</p></div>
        <Link href="/app/comercial/tabelas" className={btn}>Gerenciar tabelas</Link>
      </div>
    </div>

    <p className="mt-8 text-xs text-slate-500">Catálogo anterior (rotas por produto e modalidade) continua disponível em <Link href="/app/catalogo" className="underline">Catálogo</Link> para o que já existe.</p>
  </section>
}
