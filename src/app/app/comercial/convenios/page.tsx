import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createAgreement, enableAgreementTemplate, renameCatalogItem, setActive } from '../actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function AgreementsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p>Sem permissão.</p></section>
  const [agreements, templates] = await Promise.all([
    supabase.from('organization_agreements').select('id,name,template_id,is_active').order('name'),
    supabase.from('national_agreement_templates').select('id,kind,name,uf').eq('is_active', true).order('sort_order'),
  ])
  const rows = agreements.data ?? []
  const enabled = new Set(rows.map(a => a.template_id).filter(Boolean))
  const govs = (templates.data ?? []).filter(t => t.kind === 'state_government' && !enabled.has(t.id))
  const halls = (templates.data ?? []).filter(t => t.kind === 'capital_city_hall' && !enabled.has(t.id))
  return <section>
    <Link href="/app/comercial" className="text-sm text-slate-400 underline">← Voltar ao Comercial</Link>
    <h1 className="mt-3 text-3xl font-semibold">Convênios</h1>
    <p className="mt-2 text-sm text-slate-400">Habilite um convênio nacional ou cadastre um convênio próprio. A lista fica aqui, sem crescer na tela principal do Comercial.</p>

    {canEdit && <div className="mt-5 grid gap-3 lg:grid-cols-2">
      <form action={enableAgreementTemplate} className={card}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><strong>Habilitar governo estadual / DF</strong><select required name="template_id" defaultValue="" className={`${field} mt-3 w-full`}><option value="" disabled>Selecione ({govs.length} disponíveis)</option>{govs.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><SubmitButton className={`${btn} mt-3`}>Habilitar convênio</SubmitButton></form>
      <form action={enableAgreementTemplate} className={card}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><strong>Habilitar prefeitura de capital</strong><select required name="template_id" defaultValue="" className={`${field} mt-3 w-full`}><option value="" disabled>Selecione ({halls.length} disponíveis)</option>{halls.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><SubmitButton className={`${btn} mt-3`}>Habilitar convênio</SubmitButton></form>
      <form action={createAgreement} className={`${card} lg:col-span-2 flex flex-wrap gap-2`}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><input required name="name" maxLength={120} placeholder="Outro convênio (prefeitura, órgão, empresa...)" className={`${field} min-w-64 flex-1`} /><SubmitButton className={btn}>Cadastrar convênio próprio</SubmitButton></form>
    </div>}

    <div className={`${card} mt-4`}>
      <div className="mb-3 text-sm text-slate-400">{rows.filter(r => r.is_active).length} ativos · {rows.length} no total</div>
      {!rows.length ? <p className="text-sm text-slate-400">Nenhum convênio habilitado.</p> : <div className="space-y-2">{rows.map(row => <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-800 p-3">
        <div><strong>{row.name}</strong><span className="ml-2 text-xs text-slate-500">· {row.template_id ? 'nacional' : 'próprio'}</span><span className={`ml-2 text-xs ${row.is_active ? 'text-emerald-300' : 'text-slate-500'}`}>{row.is_active ? 'Ativo' : 'Inativo'}</span></div>
        {canEdit && <div className="flex items-center gap-3">
          {!row.template_id && <details><summary className="cursor-pointer text-xs text-slate-300 underline">Editar nome</summary><form action={renameCatalogItem} className="mt-2 flex gap-2"><input type="hidden" name="return_to" value="/app/comercial/convenios" /><input type="hidden" name="kind" value="agreement" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className={field} /><SubmitButton className={ghost}>Salvar</SubmitButton></form></details>}
          <form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><input type="hidden" name="kind" value="agreement" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form>
        </div>}
      </div>)}</div>}
    </div>
  </section>
}
