import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { isUuid } from '@/lib/team'
import { decimalBr, rangeText, termText } from '@/lib/commission/tableValues'
import { saveLineValues } from '../../../actions'

const input = (kind: string | undefined, v: string | undefined) => (v === undefined ? '' : kind === 'fixed_brl' ? `R$ ${decimalBr(v, true)}` : decimalBr(v))

// $ Change the commission of one line by hand: what the company receives and what each seller group gets, per type.
// Only a draft vigência can change; a published one is copied into a new draft first.
export default async function LinePage({ params }: { params: Promise<{ id: string; cid: string }> }) {
  const { id, cid } = await params
  if (!isUuid(id) || !isUuid(cid)) notFound()
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return <section><PageHeader title="Comissão da linha" /><Card className="p-5 text-sm text-ink-soft">Seu papel não altera comissões.</Card></section>

  const { data: line } = await supabase.from('commercial_conditions').select('id,product_table_version_id,contract_type_id,term,term_min,term_max,amount_min,amount_max,rate,coefficient').eq('id', cid).maybeSingle()
  if (!line) notFound()
  const [{ data: version }, { data: table }, { data: type }, { data: types }, { data: groups }, { data: rules }, { data: comp }, { data: gv }] = await Promise.all([
    supabase.from('product_table_versions').select('id,version,status,product_table_id').eq('id', line.product_table_version_id).maybeSingle(),
    supabase.from('product_tables').select('id,name').eq('id', id).maybeSingle(),
    supabase.from('contract_types').select('name').eq('id', line.contract_type_id).maybeSingle(),
    supabase.from('commission_component_types').select('id,name,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active', true).order('sort_order').order('name'),
    supabase.from('commission_group_rules').select('group_id,version,own_production').order('version', { ascending: false }),
    supabase.from('commercial_condition_components').select('component_type_id,value_kind,received_value,calculation_base').eq('condition_id', cid),
    supabase.from('commercial_condition_group_values').select('group_id,component_type_id,value_kind,value').eq('condition_id', cid),
  ])
  if (!version || !table || version.product_table_id !== id) notFound()
  const own = new Map<string, boolean>()
  for (const r of rules ?? []) if (!own.has(r.group_id)) own.set(r.group_id, r.own_production)
  const payGroups = (groups ?? []).filter(g => !own.get(g.id))
  const company = new Map((comp ?? []).map(c => [c.component_type_id, c]))
  const values = new Map((gv ?? []).map(g => [`${g.group_id}:${g.component_type_id}`, g]))
  const base = (comp ?? []).find(c => c.calculation_base)?.calculation_base ?? ''
  const draft = version.status === 'draft'

  return (
    <section>
      <Link href={`/app/comercial/tabelas/${id}?v=${version.id}#comissao`} className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />{table.name}</Link>
      <PageHeader title="Comissão da linha" description={`${type?.name ?? 'Tipo'} · ${termText(line.term_min, line.term_max, line.term)} · ${rangeText(line.amount_min, line.amount_max)} · taxa ${line.rate ?? line.coefficient ?? '—'} · v${version.version}`} />
      {!draft ? <Card className="p-5 text-sm text-ink-soft">Esta vigência já foi publicada e não muda. Volte à tabela e use “Nova vigência a partir desta”.</Card> : (
        <Card className="p-5">
          <form action={saveLineValues} className="grid gap-5">
            <input type="hidden" name="table_id" value={id} /><input type="hidden" name="version_id" value={version.id} /><input type="hidden" name="condition_id" value={cid} />
            <p className="text-[13px] text-ink-soft">Digite <b>2,5</b> para 2,5% da operação ou <b>R$ 25,00</b> para valor fixo. Vazio = não vale para esta linha.</p>
            <label className="text-[13px] font-medium text-ink-soft">Base de cálculo da empresa
              <select name="calculation_base" defaultValue={base} className="field mt-1.5 max-w-xs"><option value="">Não informada</option><option value="BRUTO">Bruto</option><option value="LÍQUIDO">Líquido</option></select>
            </label>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[640px] text-left text-[13px]">
                <thead className="border-y border-line bg-surface-muted text-xs text-muted">
                  <tr><th className="px-3 py-2 font-medium">Tipo de comissão</th><th className="px-3 py-2 font-medium">Empresa recebe</th>{payGroups.map(g => <th key={g.id} className="px-3 py-2 font-medium">{g.name}</th>)}</tr>
                </thead>
                <tbody>
                  {(types ?? []).map(t => {
                    const c = company.get(t.id)
                    return (
                      <tr key={t.id} className="border-t border-line">
                        <td className="px-3 py-2 font-medium text-ink">{t.name}</td>
                        <td className="px-3 py-1.5"><input name={`c_${t.id}`} aria-label={`${t.name} — Empresa`} defaultValue={input(c?.value_kind, c?.received_value)} className="field w-32" /></td>
                        {payGroups.map(g => {
                          const v = values.get(`${g.id}:${t.id}`)
                          return <td key={g.id} className="px-3 py-1.5"><input name={`g_${g.id}_${t.id}`} aria-label={`${t.name} — ${g.name}`} defaultValue={input(v?.value_kind, v?.value)} className="field w-28" /></td>
                        })}
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
            <div className="flex justify-end"><SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Salvar comissão da linha</SubmitButton></div>
          </form>
        </Card>
      )}
    </section>
  )
}
