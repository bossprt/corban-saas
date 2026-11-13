import { Badge, Card } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { brl, CHARGE_STATE, dayLabel, monthLabel } from '@/lib/billing'
import { markChargePaid, reverseCharge, saveBillingSettings } from './actions'
import { SubscriptionForm } from './SubscriptionForm'

type Settings = { pix_key: string; pix_key_type: string; merchant_name: string; merchant_city: string } | null
type Sub = { organization_id: string; amount: string; due_day: number; grace_days: number; starts_on: string; is_active: boolean }
type Charge = { id: string; organization_id: string; period: string; amount: string; due_on: string; block_on: string; state: string; paid_on: string | null }

const button = 'inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const KEY_TYPES: [string, string][] = [['cpf', 'CPF'], ['cnpj', 'CNPJ'], ['email', 'E-mail'], ['phone', 'Celular'], ['random', 'Aleatória']]

// Monthly fee (03/11/2026): who receives the Pix, what each company pays, and the confirmation of each payment.
export function BillingSection({ settings, subs, charges, orgs, today }: { settings: Settings; subs: Sub[]; charges: Charge[]; orgs: { id: string; name: string }[]; today: string }) {
  const sub = new Map(subs.map(s => [s.organization_id, s]))
  const orgName = new Map(orgs.map(o => [o.id, o.name]))
  return <section>
    <p className="text-sm text-muted">A mensalidade de cada empresa aparece para o administrador dela no dia do vencimento, com o Pix. Depois da carência sem pagamento, o acesso da empresa fica bloqueado até você confirmar o recebimento.</p>

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
    <p className="mt-1 text-sm text-muted">O primeiro mês começa no mês atual ou depois. Um mês passado criaria mensalidades já vencidas e bloquearia a empresa na hora, por isso não é aceito.</p>
    <div className="mt-3 space-y-3">{orgs.map(o => <Card key={o.id} className="p-4">
      <SubscriptionForm orgId={o.id} orgName={o.name} sub={sub.get(o.id)} today={today} />
    </Card>)}</div>

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
