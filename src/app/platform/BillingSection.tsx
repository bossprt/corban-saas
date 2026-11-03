import { Badge, Card } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { brl, CHARGE_STATE, dayLabel, monthLabel } from '@/lib/billing'
import { markChargePaid, reverseCharge, saveBillingSettings, saveSubscription } from './actions'

type Settings = { pix_key: string; pix_key_type: string; merchant_name: string; merchant_city: string } | null
type Sub = { organization_id: string; amount: string; due_day: number; grace_days: number; starts_on: string; is_active: boolean }
type Charge = { id: string; organization_id: string; period: string; amount: string; due_on: string; block_on: string; state: string; paid_on: string | null }

const button = 'inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const KEY_TYPES: [string, string][] = [['cpf', 'CPF'], ['cnpj', 'CNPJ'], ['email', 'E-mail'], ['phone', 'Celular'], ['random', 'Aleatória']]

// Monthly fee (03/11/2026): who receives the Pix, what each company pays, and the confirmation of each payment.
export function BillingSection({ settings, subs, charges, orgs, today }: { settings: Settings; subs: Sub[]; charges: Charge[]; orgs: { id: string; name: string }[]; today: string }) {
  const sub = new Map(subs.map(s => [s.organization_id, s]))
  const orgName = new Map(orgs.map(o => [o.id, o.name]))
  return <section className="mt-8">
    <h2 className="text-xl font-semibold text-ink">Cobrança</h2>
    <p className="mt-1 text-sm text-muted">A mensalidade de cada empresa aparece para o administrador dela no dia do vencimento, com o Pix. Depois da carência sem pagamento, o acesso da empresa fica bloqueado até você confirmar o recebimento.</p>

    <Card className="mt-3 p-5">
      <h3 className="font-semibold text-ink">Recebedor do Pix</h3>
      <form action={saveBillingSettings} className="mt-3 grid gap-3 sm:grid-cols-[140px_1fr_1fr_1fr_auto] sm:items-end">
        <label className="text-xs text-muted">Tipo da chave<select name="pix_key_type" defaultValue={settings?.pix_key_type ?? 'cpf'} className="field mt-1 block">{KEY_TYPES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <label className="text-xs text-muted">Chave Pix<input name="pix_key" required maxLength={77} defaultValue={settings?.pix_key ?? ''} autoComplete="off" className="field mt-1 block" /></label>
        <label className="text-xs text-muted">Nome (até 25)<input name="merchant_name" required maxLength={25} defaultValue={settings?.merchant_name ?? ''} className="field mt-1 block" /></label>
        <label className="text-xs text-muted">Cidade (até 15)<input name="merchant_city" required maxLength={15} defaultValue={settings?.merchant_city ?? ''} className="field mt-1 block" /></label>
        <SubmitButton pendingText="Salvando..." className={button}>Salvar</SubmitButton>
      </form>
    </Card>

    <h3 className="mt-6 text-lg font-semibold text-ink">Assinaturas</h3>
    <div className="mt-3 space-y-3">{orgs.map(o => { const s = sub.get(o.id); return <Card key={o.id} className="p-4">
      <form action={saveSubscription} className="grid gap-3 sm:grid-cols-[1fr_120px_90px_90px_140px_auto_auto] sm:items-end">
        <input type="hidden" name="organization_id" value={o.id} />
        <div className="text-sm font-semibold text-ink">{o.name}<div className="text-xs font-normal text-muted">{s ? (s.is_active ? 'Cobrança ligada' : 'Cobrança desligada') : 'Sem assinatura'}</div></div>
        <label className="text-xs text-muted">Valor (R$)<input name="amount" required inputMode="decimal" defaultValue={s ? s.amount.replace('.', ',') : ''} placeholder="399,90" className="field mt-1 block" /></label>
        <label className="text-xs text-muted">Dia<input name="due_day" required type="number" min={1} max={28} defaultValue={s?.due_day ?? 3} className="field mt-1 block" /></label>
        <label className="text-xs text-muted">Carência<input name="grace_days" required type="number" min={0} max={30} defaultValue={s?.grace_days ?? 5} className="field mt-1 block" /></label>
        <label className="text-xs text-muted">Primeiro mês<input name="starts_on" required type="month" defaultValue={s ? s.starts_on.slice(0, 7) : today.slice(0, 7)} className="field mt-1 block" /></label>
        <label className="flex items-center gap-1.5 text-xs text-muted sm:pb-3"><input type="checkbox" name="is_active" defaultChecked={s?.is_active ?? true} className="accent-[var(--brand)]" />Ligada</label>
        <SubmitButton pendingText="Salvando..." className={button}>Salvar</SubmitButton>
      </form>
    </Card> })}</div>

    <h3 className="mt-6 text-lg font-semibold text-ink">Mensalidades</h3>
    <div className="mt-3 space-y-2">{charges.map(c => { const [label, tone] = CHARGE_STATE[c.state] ?? [c.state, 'neutral' as const]; return <Card key={c.id} className="p-4">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2 text-sm">
        <span className="font-medium text-ink">{orgName.get(c.organization_id) ?? 'Empresa'}</span>
        <span className="text-ink-soft">{monthLabel(c.period)} · {brl(c.amount)} · venc. {dayLabel(c.due_on)}</span>
        <Badge tone={tone}>{c.paid_on ? `Paga em ${dayLabel(c.paid_on)}` : label}</Badge>
        {c.paid_on ? (
          <form action={reverseCharge} className="ml-auto flex flex-wrap items-center gap-2">
            <input type="hidden" name="charge_id" value={c.id} /><input type="hidden" name="organization_id" value={c.organization_id} />
            <input name="note" required minLength={3} maxLength={500} placeholder="Motivo do estorno" className="field h-9 w-56" />
            <SubmitButton pendingText="Estornando..." className="h-9 rounded-[10px] border border-line px-3 text-sm text-ink-soft hover:bg-surface-muted">Estornar</SubmitButton>
          </form>
        ) : (
          <form action={markChargePaid} className="ml-auto flex flex-wrap items-center gap-2">
            <input type="hidden" name="charge_id" value={c.id} /><input type="hidden" name="organization_id" value={c.organization_id} />
            <label className="text-xs text-muted">Recebido em <input name="paid_on" type="date" required max={today} defaultValue={today} className="field ml-1 h-9 w-40" /></label>
            <SubmitButton pendingText="Confirmando..." className="h-9 rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong">Recebido</SubmitButton>
          </form>
        )}
      </div>
    </Card> })}
    {!charges.length && <Card className="p-4"><p className="text-sm text-muted">Nenhuma mensalidade criada ainda. Ela aparece no dia do vencimento.</p></Card>}
    </div>
  </section>
}
