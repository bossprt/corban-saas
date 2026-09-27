import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { FIN_KIND_LABEL } from '@/lib/finance/labels'
import { FinanceTabs } from '../FinanceTabs'
import { saveChartAccount } from '../actions'

type Account = { id: string; code: string; name: string; kind: string; is_group: boolean; system_key: string | null; is_active: boolean }
const label = 'text-[13px] font-medium text-ink-soft'

// Chart of accounts: starts from a standard for credit correspondents; the owner renames, adds and switches off lines.
export default async function ChartPage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Plano de contas" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  await supabase.rpc('fin_setup', { p_org: organization.id })
  const edit = can(access, 'financeiro.edit')
  const { data } = await supabase.from('fin_chart_accounts').select('id,code,name,kind,is_group,system_key,is_active')
  const rows = ((data ?? []) as Account[]).sort((a, b) => a.code.localeCompare(b.code, 'pt-BR', { numeric: true }))
  const kinds = Object.entries(FIN_KIND_LABEL)

  return (
    <section>
      <PageHeader title="Plano de contas" description="Grupos organizam; os lançamentos vão nas outras linhas. O tipo decide a linha da DRE. As contas marcadas como automáticas recebem a comissão, o estorno e o repasse." />
      <FinanceTabs current="/app/financeiro/empresa/plano" />
      {edit && (
        <Card className="mb-4">
          <CardHeader title="Nova conta" />
          <form action={saveChartAccount} className="grid gap-3 px-5 pb-5 sm:grid-cols-5">
            <label className={label}>Código<input name="code" required pattern="[0-9]{1,3}(\.[0-9]{1,3}){0,3}" placeholder="4.10" className="field mt-1.5" /></label>
            <label className={`${label} sm:col-span-2`}>Nome<input name="name" required minLength={2} maxLength={80} className="field mt-1.5" /></label>
            <label className={label}>Tipo<select name="kind" className="field mt-1.5">{kinds.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <div className="flex items-end justify-between gap-2">
              <label className="flex items-center gap-2 text-sm text-ink-soft"><input type="checkbox" name="is_group" className="size-4 accent-[var(--brand)]" />Grupo</label>
              <SubmitButton className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="...">Adicionar</SubmitButton>
            </div>
          </form>
        </Card>
      )}
      <Card className="overflow-hidden">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-muted text-xs text-muted"><tr><th className="px-4 py-2">Código e nome</th><th className="px-4 py-2">Tipo</th><th className="px-4 py-2">Situação</th></tr></thead>
          <tbody>
            {rows.map(a => (
              <tr key={a.id} className="border-t border-line">
                <td className="px-4 py-2">
                  {edit ? (
                    <form action={saveChartAccount} className="flex flex-wrap items-center gap-2">
                      <input type="hidden" name="id" value={a.id} /><input type="hidden" name="kind" value={a.kind} />
                      {a.is_group && <input type="hidden" name="is_group" value="on" />}
                      <input name="code" required defaultValue={a.code} aria-label={`Código de ${a.name}`} className="field h-8 w-20 py-0 text-sm" />
                      <input name="name" required defaultValue={a.name} aria-label={`Nome de ${a.code}`} className={`field h-8 w-72 py-0 text-sm ${a.is_group ? 'font-semibold' : ''}`} />
                      <select name="is_active" defaultValue={a.is_active ? 'true' : 'false'} aria-label="Situação" className="field h-8 w-auto py-0 text-xs"><option value="true">Ativa</option><option value="false">Desativada</option></select>
                      <button className="h-8 rounded-lg border border-line px-2.5 text-xs hover:bg-surface-muted">Salvar</button>
                    </form>
                  ) : <span className={a.is_group ? 'font-semibold' : ''}>{a.code} {a.name}</span>}
                </td>
                <td className="px-4 py-2 text-ink-soft">{a.is_group ? 'Grupo · ' : ''}{FIN_KIND_LABEL[a.kind]}</td>
                <td className="px-4 py-2">{a.system_key && <Badge tone="brand">Automática</Badge>} {!a.is_active && <Badge tone="neutral">Desativada</Badge>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </section>
  )
}
