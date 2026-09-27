import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { Card, PageHeader, Badge } from '@/components/ui'
import { createAgreement, enableAgreementTemplate, renameCatalogItem, setActive } from '../actions'

const btn = 'inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost = 'h-9 rounded-[10px] border border-line bg-surface px-3 text-xs hover:bg-surface-muted'

export default async function AgreementsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p className="text-sm text-muted">Sem permissão.</p></section>
  const [agreements, templates] = await Promise.all([
    supabase.from('organization_agreements').select('id,name,template_id,is_active').order('name'),
    supabase.from('national_agreement_templates').select('id,kind,name,uf').eq('is_active', true).order('sort_order'),
  ])
  const rows = agreements.data ?? []
  const enabled = new Set(rows.map(a => a.template_id).filter(Boolean))
  const govs = (templates.data ?? []).filter(t => t.kind === 'state_government' && !enabled.has(t.id))
  const halls = (templates.data ?? []).filter(t => t.kind === 'capital_city_hall' && !enabled.has(t.id))
  return <section>
    <Link href="/app/cadastros" className="text-sm text-brand hover:underline">← Cadastros</Link>
    <PageHeader title="Convênios" description="Habilite um convênio nacional ou cadastre um convênio próprio. A lista fica aqui, sem crescer na tela principal do Comercial." />

    {canEdit && <div className="grid gap-3 lg:grid-cols-2">
      <Card className="p-5"><form action={enableAgreementTemplate}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><strong className="text-ink">Habilitar governo estadual / DF</strong><select required name="template_id" defaultValue="" className="field mt-3 w-full"><option value="" disabled>Selecione ({govs.length} disponíveis)</option>{govs.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><SubmitButton className={`${btn} mt-3`}>Habilitar convênio</SubmitButton></form></Card>
      <Card className="p-5"><form action={enableAgreementTemplate}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><strong className="text-ink">Habilitar prefeitura de capital</strong><select required name="template_id" defaultValue="" className="field mt-3 w-full"><option value="" disabled>Selecione ({halls.length} disponíveis)</option>{halls.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><SubmitButton className={`${btn} mt-3`}>Habilitar convênio</SubmitButton></form></Card>
      <Card className="p-5 lg:col-span-2"><form action={createAgreement} className="flex flex-wrap gap-2"><input type="hidden" name="return_to" value="/app/comercial/convenios" /><input required name="name" maxLength={120} placeholder="Outro convênio (prefeitura, órgão, empresa...)" className="field min-w-64 flex-1" /><SubmitButton className={btn}>Cadastrar convênio próprio</SubmitButton></form></Card>
    </div>}

    <Card className="mt-4 p-5">
      <div className="mb-3 text-sm text-muted">{rows.filter(r => r.is_active).length} ativos · {rows.length} no total</div>
      {!rows.length ? <p className="text-sm text-muted">Nenhum convênio habilitado.</p> : <div className="space-y-2">{rows.map(row => <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-[10px] border border-line p-3">
        <div><strong className="text-ink">{row.name}</strong><span className="ml-2 text-xs text-muted">· {row.template_id ? 'nacional' : 'próprio'}</span><Badge tone={row.is_active ? 'received' : 'neutral'} className="ml-2">{row.is_active ? 'Ativo' : 'Inativo'}</Badge></div>
        {canEdit && <div className="flex items-center gap-3">
          {!row.template_id && <details><summary className="cursor-pointer text-xs text-brand underline">Editar nome</summary><form action={renameCatalogItem} className="mt-2 flex gap-2"><input type="hidden" name="return_to" value="/app/comercial/convenios" /><input type="hidden" name="kind" value="agreement" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className="field" /><SubmitButton className={ghost}>Salvar</SubmitButton></form></details>}
          <form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/convenios" /><input type="hidden" name="kind" value="agreement" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form>
        </div>}
      </div>)}</div>}
    </Card>
  </section>
}
