import Link from 'next/link'
import { ArrowLeft, FileCheck2 } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { saveBankChecklist } from './actions'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
type Item = { template_id: string; document_type_id: string; label: string; is_required: boolean; sort_order: number }

// Documentos por banco: the documents each bank (and convênio) asks for. Saved as the published checklist of each route
// (bank + convênio + own or partner production); "Preparar checklist" on a proposal copies it into the proposal.
export default async function BankChecklistPage({ searchParams }: { searchParams: Promise<{ banco?: string }> }) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) {
    return <section><PageHeader title="Documentos por banco" /><Card className="p-5 text-sm text-ink-soft">Área restrita a supervisão, gerência e administração.</Card></section>
  }
  const sp = await searchParams
  const [{ data: banks }, { data: routes }, { data: agreements }, { data: providers }, { data: types }, { data: templates }] = await Promise.all([
    supabase.from('organization_banks').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_agreement_id,org_provider_id,production_origin').eq('status', 'active'),
    supabase.from('organization_agreements').select('id,name'),
    supabase.from('organization_providers').select('id,name'),
    supabase.from('document_types').select('id,name').eq('is_active', true).order('name'),
    supabase.from('document_checklist_templates').select('id,route_id,version,published_at').eq('status', 'published'),
  ])
  const templateIds = (templates ?? []).map(t => t.id)
  const { data: items } = templateIds.length
    ? await supabase.from('document_checklist_items').select('template_id,document_type_id,label,is_required,sort_order').in('template_id', templateIds).order('sort_order')
    : { data: [] as Item[] }
  const agreementName = new Map((agreements ?? []).map(a => [a.id, a.name]))
  const providerName = new Map((providers ?? []).map(p => [p.id, p.name]))
  const templateByRoute = new Map((templates ?? []).map(t => [t.route_id, t]))
  const itemsByTemplate = new Map<string, Item[]>()
  for (const i of (items ?? []) as Item[]) itemsByTemplate.set(i.template_id, [...(itemsByTemplate.get(i.template_id) ?? []), i])
  const routeLabel = (r: { org_agreement_id: string | null; org_provider_id: string | null; production_origin: string | null }) =>
    `${agreementName.get(r.org_agreement_id ?? '') ?? 'Convênio'}${r.production_origin === 'third_party' ? ` · via ${providerName.get(r.org_provider_id ?? '') ?? 'promotora'}` : ''}`

  const routesOf = (bankId: string) => (routes ?? []).filter(r => r.org_bank_id === bankId).sort((a, b) => routeLabel(a).localeCompare(routeLabel(b), 'pt-BR'))
  const bank = (banks ?? []).find(b => b.id === (UUID.test(sp.banco ?? '') ? sp.banco : (banks ?? [])[0]?.id))
  const bankRoutes = bank ? routesOf(bank.id) : []
  // The form starts from the list of the first convênio that has one (usually all convênios of a bank share it).
  const base = bankRoutes.map(r => templateByRoute.get(r.id)).find(Boolean)
  const baseItems = new Map((base ? itemsByTemplate.get(base.id) ?? [] : []).map(i => [i.document_type_id, i]))

  return (
    <section>
      <Link href="/app/cadastros" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Cadastros</Link>
      <PageHeader title="Documentos por banco" description="Marque o que cada banco pede. Na proposta, “Preparar checklist” traz esta lista e a proposta só segue para digitação com os obrigatórios validados." />

      {!(banks ?? []).length && <Card className="p-5 text-sm text-ink-soft">Nenhum banco cadastrado. Cadastre em Cadastros &gt; Bancos.</Card>}

      {bank && (
        <div className="grid gap-4 lg:grid-cols-[260px_1fr]">
          <Card className="h-fit overflow-hidden">
            <ul className="py-1.5">
              {(banks ?? []).map(b => {
                const rs = routesOf(b.id)
                const done = rs.filter(r => templateByRoute.has(r.id)).length
                return (
                  <li key={b.id}>
                    <Link href={`/app/cadastros/documentos-banco?banco=${b.id}`} aria-current={b.id === bank.id ? 'page' : undefined}
                      className={`flex items-center justify-between gap-2 px-4 py-2.5 text-sm ${b.id === bank.id ? 'bg-brand/10 font-semibold text-brand' : 'text-ink hover:bg-surface-muted'}`}>
                      <span className="truncate">{b.name}</span>
                      <span className={`num shrink-0 text-xs ${rs.length && done === rs.length ? 'text-[#166534]' : 'text-muted'}`}>{rs.length ? `${done}/${rs.length}` : '—'}</span>
                    </Link>
                  </li>
                )
              })}
            </ul>
          </Card>

          <div className="grid content-start gap-4">
            {bankRoutes.length === 0 ? (
              <Card className="p-5 text-sm text-ink-soft">{bank.name} ainda não tem convênio ligado. O banco e o convênio são ligados quando uma tabela dele é cadastrada em Cadastros &gt; Tabelas.</Card>
            ) : (
              <>
                <Card>
                  <CardHeader title={`${bank.name}: lista atual por convênio`} />
                  <ul className="px-5 pb-4 pt-2">
                    {bankRoutes.map(r => {
                      const t = templateByRoute.get(r.id)
                      const list = t ? itemsByTemplate.get(t.id) ?? [] : []
                      return (
                        <li key={r.id} className="border-t border-line py-2.5 text-sm first:border-t-0">
                          <span className="flex flex-wrap items-center gap-2 font-medium text-ink">{routeLabel(r)}{t ? <Badge tone="received">v{t.version}</Badge> : <Badge tone="diverged">Sem lista</Badge>}</span>
                          {list.length > 0 && <span className="mt-0.5 block text-ink-soft">{list.map(i => `${i.label}${i.is_required ? '' : ' (opcional)'}`).join(' · ')}</span>}
                        </li>
                      )
                    })}
                  </ul>
                </Card>

                <Card className="p-5">
                  <h2 className="mb-4 flex items-center gap-2 text-base font-semibold text-ink"><FileCheck2 size={18} className="text-brand" aria-hidden />Definir a lista de {bank.name}</h2>
                  <form action={saveBankChecklist} className="grid gap-5">
                    <input type="hidden" name="bank_id" value={bank.id} />
                    <fieldset>
                      <legend className="mb-2 text-[13px] font-medium text-ink-soft">Vale para os convênios</legend>
                      <div className="flex flex-wrap gap-x-5 gap-y-2">
                        {bankRoutes.map(r => (
                          <label key={r.id} className="flex items-center gap-2 text-sm text-ink">
                            <input type="checkbox" name="route_id" value={r.id} defaultChecked className="accent-[var(--brand)]" />{routeLabel(r)}
                          </label>
                        ))}
                      </div>
                    </fieldset>
                    <fieldset>
                      <legend className="mb-2 text-[13px] font-medium text-ink-soft">Documentos que o banco pede</legend>
                      <div className="overflow-hidden rounded-[10px] border border-line">
                        <table className="w-full text-left text-sm">
                          <thead className="bg-surface-muted text-xs text-muted"><tr><th className="w-16 px-4 py-2 font-medium">Pede</th><th className="px-3 py-2 font-medium">Documento</th><th className="w-44 px-4 py-2 font-medium">Como</th></tr></thead>
                          <tbody>
                            {(types ?? []).map(t => {
                              const cur = baseItems.get(t.id)
                              return (
                                <tr key={t.id} className="border-t border-line">
                                  <td className="px-4 py-2"><input type="checkbox" name="doc" value={t.id} defaultChecked={!!cur} aria-label={`Pede ${t.name}`} className="size-4 accent-[var(--brand)]" /></td>
                                  <td className="px-3 py-2 text-ink">{t.name}</td>
                                  <td className="px-4 py-2">
                                    <select name={`req_${t.id}`} defaultValue={cur && !cur.is_required ? 'optional' : 'required'} aria-label={`Obrigatório ${t.name}`} className="field h-9 py-0 text-sm">
                                      <option value="required">Obrigatório</option>
                                      <option value="optional">Opcional</option>
                                    </select>
                                  </td>
                                </tr>
                              )
                            })}
                          </tbody>
                        </table>
                      </div>
                    </fieldset>
                    <div className="flex flex-wrap items-center gap-3">
                      <SubmitButton pendingText="Salvando..." className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Salvar lista</SubmitButton>
                      <span className="text-xs text-muted">Salvar cria uma nova versão. Propostas que já prepararam o checklist continuam com a lista da época.</span>
                    </div>
                  </form>
                </Card>
              </>
            )}
          </div>
        </div>
      )}
    </section>
  )
}
