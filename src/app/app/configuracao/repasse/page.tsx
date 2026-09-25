import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { canManageTeam } from '@/lib/rbac'
import { FREQUENCY_LABEL, MODEL_LABEL } from '@/lib/payout/format'
import { savePayoutSettings } from '../../repasse/actions'

const label = 'text-[13px] font-medium text-ink-soft'

// Company payout policy: default model (each person may have an exception on their account), closing frequency and
// how much of each statement may go to pay a negative balance.
export default async function PayoutSettingsPage() {
  const { supabase, membership, access } = await requireAppContext()
  if (!canManageTeam(membership.role) || !can(access, 'repasse.edit')) {
    return <section><PageHeader title="Repasse" /><Card className="p-5 text-sm text-ink-soft">Somente administrador e gerente configuram o repasse.</Card></section>
  }
  const { data: s } = await supabase.from('payout_settings').select('default_model,closing_frequency,debt_limit_pct').maybeSingle()
  const limit = s ? String(s.debt_limit_pct).replace(/\.?0+$/, '').replace('.', ',') : '30'
  return (
    <section>
      <PageHeader title="Repasse" description="Como a equipe recebe. Mudanças valem para os próximos fechamentos e saques; quem já tem histórico mantém o modelo que tinha." />
      <Card className="p-5">
        <form action={savePayoutSettings} className="grid gap-4 sm:grid-cols-3">
          <label className={label}>Modelo padrão
            <select name="default_model" defaultValue={s?.default_model ?? 'closing'} className="field mt-1.5">
              {Object.entries(MODEL_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </label>
          <label className={label}>Frequência do fechamento
            <select name="closing_frequency" defaultValue={s?.closing_frequency ?? 'monthly'} className="field mt-1.5">
              {Object.entries(FREQUENCY_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </label>
          <label className={label}>Desconto máximo do saldo negativo por repasse (%)
            <input name="debt_limit_pct" inputMode="decimal" defaultValue={limit} className="field mt-1.5" />
          </label>
          <p className="text-xs text-muted sm:col-span-3">Exemplo com 30%: quem está com −100,00 e ganha 253,80 no período recebe 177,66 (desconto de 76,14) e continua com −23,86 para o próximo.</p>
          <div className="flex justify-end sm:col-span-3"><button className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong">Salvar</button></div>
        </form>
      </Card>
    </section>
  )
}
