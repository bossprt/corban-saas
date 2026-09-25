import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { canManageTeam } from '@/lib/rbac'
import { saveRule, setTaxExempt } from './actions'

type Rule = { id: string; scope_kind: string; scope_id: string | null; effective_from: string; mode: string | null; tax_rate_pct: string | null; profit_pct: string | null; manager_pct: string | null; supervisor_pct: string | null; originator_pct: string | null; pay_deferred: boolean | null; note: string | null }

const SCOPE_LABEL: Record<string, string> = { global: 'Empresa (padrão)', bank: 'Banco', table: 'Tabela', group: 'Grupo de vendedores', seller: 'Vendedor' }
const MODE_LABEL: Record<string, string> = { cascade: 'Cascata', group_table: 'Tabela por grupo' }
// '6.0000' -> '6', '6.5000' -> '6,5' (decimal strings from the database, never floats).
const trim = (v: string | null | undefined) => (v === null || v === undefined ? '' : (String(v).includes('.') ? String(v).replace(/0+$/, '').replace(/\.$/, '') : String(v)).replace('.', ','))
const pct = (v: string | null) => (v === null ? '—' : `${trim(v)}%`)
const label = 'text-[13px] font-medium text-ink-soft'

// Owner commission rules: the company default and more specific rules per bank, table, commission group or seller.
// Each save is a new version; the latest per scope applies, field by field, the most specific one winning.
export default async function CommissionSettingsPage() {
  const { supabase, membership, access } = await requireAppContext()
  if (!canManageTeam(membership.role) || !can(access, 'comercial.view')) {
    return <section><PageHeader title="Comissão" /><Card className="p-5 text-sm text-ink-soft">Somente administrador e gerente configuram a comissão.</Card></section>
  }
  const [{ data: rules }, { data: banks }, { data: providers }, { data: tables }, { data: groups }, { data: sellers }] = await Promise.all([
    supabase.from('commission_rule_versions').select('id,scope_kind,scope_id,effective_from,mode,tax_rate_pct,profit_pct,manager_pct,supervisor_pct,originator_pct,pay_deferred,note').order('effective_from', { ascending: false }).limit(300),
    supabase.from('organization_banks').select('id,name,tax_exempt').eq('is_active', true).order('name'),
    supabase.from('organization_providers').select('id,name,tax_exempt').eq('is_active', true).order('name'),
    supabase.from('product_tables').select('id,name,code').eq('status', 'active').order('name'),
    supabase.from('commission_groups').select('id,name').eq('is_active', true).order('name'),
    supabase.from('commercial_sellers').select('id,name').eq('is_active', true).order('name'),
  ])
  const all = (rules ?? []) as Rule[]
  // Latest version per scope.
  const latest = new Map<string, Rule>()
  for (const r of all) { const k = `${r.scope_kind}:${r.scope_id ?? ''}`; if (!latest.has(k)) latest.set(k, r) }
  const global = latest.get('global:')
  const specific = [...latest.values()].filter(r => r.scope_kind !== 'global')
  const names = new Map<string, string>([...(banks ?? []), ...(tables ?? []), ...(groups ?? []), ...(sellers ?? [])].map(x => [x.id, x.name]))
  const mode = global?.mode ?? 'cascade'

  return (
    <section>
      <PageHeader title="Comissão" description="Como a comissão recebida do banco é dividida: imposto, lucro da empresa e repasse. Todos os percentuais são seus; cada alteração vira uma nova versão e as propostas já calculadas não mudam." />

      <Card className="mb-4">
        <CardHeader title="Regra padrão da empresa" action={global ? <Badge tone="received">Em vigor desde {new Date(global.effective_from).toLocaleDateString('pt-BR')}</Badge> : <Badge tone="diverged">Não configurada</Badge>} />
        <form action={saveRule} className="grid gap-4 p-5 pt-3 sm:grid-cols-3">
          <input type="hidden" name="scope_kind" value="global" />
          <fieldset className="sm:col-span-3">
            <legend className={label}>Modo de repasse</legend>
            <div className="mt-1.5 flex flex-wrap gap-5 text-sm text-ink">
              <label className="flex items-center gap-2"><input type="radio" name="mode" value="cascade" defaultChecked={mode === 'cascade'} className="accent-[var(--brand)]" />Cascata: imposto → lucro da empresa → gerente, supervisor e vendedor</label>
              <label className="flex items-center gap-2"><input type="radio" name="mode" value="group_table" defaultChecked={mode === 'group_table'} className="accent-[var(--brand)]" />Tabela por grupo: vendedor recebe o % do grupo dele na tabela; empresa fica com a sobra</label>
            </div>
          </fieldset>
          <label className={label}>Imposto do regime (%)<input name="tax_rate_pct" inputMode="decimal" defaultValue={trim(global?.tax_rate_pct)} placeholder="6" className="field mt-1.5" /></label>
          <label className={label}>Lucro da empresa (%) <span className="font-normal text-muted">cascata</span><input name="profit_pct" inputMode="decimal" defaultValue={trim(global?.profit_pct)} placeholder="40" className="field mt-1.5" /></label>
          <label className={label}>Diferido para a equipe
            <select name="pay_deferred" defaultValue={global?.pay_deferred === false ? 'false' : 'true'} className="field mt-1.5">
              <option value="true">Sim, o diferido também é repassado</option>
              <option value="false">Não, o diferido fica com a empresa</option>
            </select>
          </label>
          <label className={label}>Gerente (%)<input name="manager_pct" inputMode="decimal" defaultValue={trim(global?.manager_pct)} placeholder="10" className="field mt-1.5" /></label>
          <label className={label}>Supervisor (%)<input name="supervisor_pct" inputMode="decimal" defaultValue={trim(global?.supervisor_pct)} placeholder="15" className="field mt-1.5" /></label>
          <label className={label}>Vendedor (%) <span className="font-normal text-muted">cascata, ou padrão sem grupo</span><input name="originator_pct" inputMode="decimal" defaultValue={trim(global?.originator_pct)} placeholder="75" className="field mt-1.5" /></label>
          <p className="text-xs text-muted sm:col-span-3">No modo cascata, gerente, supervisor e vendedor são % do que sobra depois do imposto e do lucro; sem gerente ou supervisor na venda, a parte deles fica com a empresa. No modo tabela, gerente e supervisor são % da comissão já sem imposto.</p>
          <div className="flex justify-end sm:col-span-3"><button className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong">Salvar nova versão</button></div>
        </form>
      </Card>

      <div className="grid gap-4 lg:grid-cols-[1.3fr_1fr]">
        <Card>
          <CardHeader title="Regras específicas" />
          <div className="overflow-x-auto px-2 pb-2 pt-2">
            <table className="w-full text-left text-[13px]">
              <thead className="text-xs text-muted"><tr><th className="px-3 py-2 font-medium">Aplica a</th><th className="px-3 py-2 font-medium">Modo</th><th className="px-3 py-2 font-medium">Lucro</th><th className="px-3 py-2 font-medium">Gerente</th><th className="px-3 py-2 font-medium">Supervisor</th><th className="px-3 py-2 font-medium">Vendedor</th><th className="px-3 py-2 font-medium">Diferido</th></tr></thead>
              <tbody>
                {specific.map(r => (
                  <tr key={r.id} className="border-t border-line">
                    <td className="px-3 py-2 text-ink">{SCOPE_LABEL[r.scope_kind]}: {names.get(r.scope_id ?? '') ?? '—'}</td>
                    <td className="px-3 py-2 text-ink-soft">{r.mode ? MODE_LABEL[r.mode] : 'herda'}</td>
                    <td className="num px-3 py-2">{pct(r.profit_pct)}</td>
                    <td className="num px-3 py-2">{pct(r.manager_pct)}</td>
                    <td className="num px-3 py-2">{pct(r.supervisor_pct)}</td>
                    <td className="num px-3 py-2">{pct(r.originator_pct)}</td>
                    <td className="px-3 py-2 text-ink-soft">{r.pay_deferred === null ? 'herda' : r.pay_deferred ? 'repassa' : 'empresa'}</td>
                  </tr>
                ))}
                {specific.length === 0 && <tr><td colSpan={7} className="px-3 py-6 text-center text-muted">Nenhuma regra específica. Tudo segue a regra padrão.</td></tr>}
              </tbody>
            </table>
          </div>
          <form action={saveRule} className="grid gap-3 border-t border-line p-5 sm:grid-cols-4">
            <p className="text-sm font-medium text-ink sm:col-span-4">Nova regra específica <span className="font-normal text-muted">(campos vazios herdam da regra mais geral)</span></p>
            <label className={`${label} sm:col-span-4`}>Aplica a
              <select name="target" required defaultValue="" className="field mt-1.5">
                <option value="" disabled>Escolha banco, tabela, grupo ou vendedor</option>
                <optgroup label="Banco">{(banks ?? []).map(b => <option key={b.id} value={`bank:${b.id}`}>{b.name}</option>)}</optgroup>
                <optgroup label="Tabela">{(tables ?? []).map(t => <option key={t.id} value={`table:${t.id}`}>{t.name}</option>)}</optgroup>
                <optgroup label="Grupo de vendedores">{(groups ?? []).map(g => <option key={g.id} value={`group:${g.id}`}>{g.name}</option>)}</optgroup>
                <optgroup label="Vendedor">{(sellers ?? []).map(x => <option key={x.id} value={`seller:${x.id}`}>{x.name}</option>)}</optgroup>
              </select>
            </label>
            <label className={label}>Modo<select name="mode" defaultValue="" className="field mt-1.5"><option value="">Herda</option><option value="cascade">Cascata</option><option value="group_table">Tabela por grupo</option></select></label>
            <label className={label}>Lucro (%)<input name="profit_pct" inputMode="decimal" className="field mt-1.5" /></label>
            <label className={label}>Gerente (%)<input name="manager_pct" inputMode="decimal" className="field mt-1.5" /></label>
            <label className={label}>Supervisor (%)<input name="supervisor_pct" inputMode="decimal" className="field mt-1.5" /></label>
            <label className={label}>Vendedor (%)<input name="originator_pct" inputMode="decimal" className="field mt-1.5" /></label>
            <label className={label}>Diferido<select name="pay_deferred" defaultValue="" className="field mt-1.5"><option value="">Herda</option><option value="true">Repassa</option><option value="false">Fica com a empresa</option></select></label>
            <div className="flex items-end justify-end sm:col-span-2"><button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted">Salvar regra</button></div>
          </form>
        </Card>

        <Card>
          <CardHeader title="Fontes pagadoras isentas de imposto" />
          <ul className="px-2 pb-3 pt-2 text-sm">
            {[...(banks ?? []).map(b => ({ ...b, kind: 'bank', label: 'Banco' })), ...(providers ?? []).map(p => ({ ...p, kind: 'provider', label: 'Promotora' }))].map(x => (
              <li key={`${x.kind}-${x.id}`} className="flex items-center justify-between gap-3 border-t border-line px-3 py-2 first:border-t-0">
                <span className="text-ink">{x.name} <span className="text-xs text-muted">· {x.label}</span></span>
                <form action={setTaxExempt} className="flex items-center gap-2">
                  <input type="hidden" name="kind" value={x.kind} /><input type="hidden" name="id" value={x.id} /><input type="hidden" name="exempt" value={x.tax_exempt ? 'false' : 'true'} />
                  {x.tax_exempt ? <Badge tone="received">Isenta</Badge> : <Badge tone="neutral">Paga imposto</Badge>}
                  <button className="text-xs text-brand hover:underline">{x.tax_exempt ? 'Passar a pagar' : 'Marcar isenta'}</button>
                </form>
              </li>
            ))}
            {!(banks ?? []).length && !(providers ?? []).length && <li className="px-3 py-4 text-muted">Nenhum banco ou promotora cadastrado.</li>}
          </ul>
        </Card>
      </div>
    </section>
  )
}
