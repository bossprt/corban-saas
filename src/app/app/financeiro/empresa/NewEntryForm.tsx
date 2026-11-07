'use client'

import { useActionState, type ReactNode } from 'react'
import { SubmitButton } from '@/components/SubmitButton'
import { createEntry, type NewEntryState } from './actions'

const label = 'text-[13px] font-medium text-ink-soft'

// New payable/receivable. A refusal keeps what was typed (the form is mounted again with the values sent) and says why.
export function NewEntryForm({ back, today, defaultBank, accountOptions, bankOptions, branches }:
  { back: string; today: string; defaultBank: string; accountOptions: ReactNode; bankOptions: ReactNode; branches: { id: string; name: string }[] }) {
  const [state, action] = useActionState<NewEntryState, FormData>(createEntry, { message: null, values: {}, nonce: 0 })
  const v = (k: string, d = '') => state.values[k] ?? d
  const sent = state.nonce > 0
  return (
    <form key={state.nonce} action={action} className="grid gap-4 px-5 pb-5 sm:grid-cols-3">
      <input type="hidden" name="return_to" value={back} />
      {state.message && <p role="alert" className="rounded-lg bg-[#FDF3DC] px-3 py-2 text-sm text-[#92400E] sm:col-span-3">{state.message}</p>}
      <label className={label}>Tipo<select name="direction" defaultValue={v('direction', 'out')} className="field mt-1.5"><option value="out">A pagar (saída)</option><option value="in">A receber (entrada)</option></select></label>
      <label className={label}>Valor (R$)<input name="amount" required inputMode="decimal" placeholder="1.234,56" defaultValue={v('amount')} className="field mt-1.5" /></label>
      <label className={label}>Vencimento<input type="date" name="due_on" required defaultValue={v('due_on', today)} className="field mt-1.5" /></label>
      <label className={label}>Descrição<input name="description" required minLength={3} maxLength={200} defaultValue={v('description')} className="field mt-1.5" /></label>
      <label className={label}>Fornecedor ou cliente<input name="counterpart" maxLength={120} defaultValue={v('counterpart')} className="field mt-1.5" /></label>
      <label className={label}>Conta do plano
        <select name="account_id" required defaultValue={v('account_id')} className="field mt-1.5"><option value="" disabled>Escolha</option>{accountOptions}</select>
      </label>
      <label className="flex items-center gap-2 text-sm text-ink-soft sm:col-span-2"><input type="checkbox" name="settled" defaultChecked={v('settled') === 'on'} className="size-4 accent-[var(--brand)]" />Já foi pago ou recebido (baixa na data do vencimento)</label>
      <label className={label}>Conta bancária <span className="font-normal text-muted">(se já pago)</span><select name="bank_account_id" defaultValue={sent ? v('bank_account_id') : defaultBank} className="field mt-1.5"><option value="">—</option>{bankOptions}</select></label>
      <details className="sm:col-span-3" open={sent && ((v('plan') !== '' && v('plan') !== 'once') || !!v('branch_id') || !!v('competence_on') || !!v('document'))}>
        <summary className="cursor-pointer text-sm text-muted underline">Mais opções: repetir ou parcelar, filial, competência, documento</summary>
        <div className="mt-3 grid gap-4 sm:grid-cols-3">
          <label className={label}>Como lançar
            <select name="plan" defaultValue={v('plan', 'once')} className="field mt-1.5">
              <option value="once">Uma vez</option>
              <option value="repeat">Repetir todo mês (mesmo valor)</option>
              <option value="split">Parcelar (dividir o valor)</option>
            </select>
          </label>
          <label className={label}>Quantas vezes <span className="font-normal text-muted">(repetir ou parcelar)</span><input type="number" name="installments" min={1} max={60} defaultValue={v('installments', '1')} className="field mt-1.5" /></label>
          <label className={label}>Intervalo
            <select name="interval" defaultValue={v('interval', 'month')} className="field mt-1.5">
              <option value="month">Todo mês</option>
              <option value="15">A cada 15 dias</option>
              <option value="7">A cada 7 dias</option>
              <option value="days">A cada X dias</option>
            </select>
          </label>
          <label className={label}>X dias <span className="font-normal text-muted">(só em “a cada X dias”)</span><input type="number" name="interval_days" min={1} max={365} placeholder="10" defaultValue={v('interval_days')} className="field mt-1.5" /></label>
          <p className="text-xs text-ink-soft sm:col-span-2">Repetir: o mesmo valor em cada data, por exemplo salário ou aluguel (R$ 1.000, 3 vezes = 3 × R$ 1.000). Parcelar: o valor é dividido (R$ 1.000 em 3 vezes = 3 × R$ 333,33). O intervalo define as datas a partir do vencimento: todo mês, a cada 15 dias (2 no mesmo mês), a cada 10 dias (3 no mesmo mês) e assim por diante.</p>
          <label className={label}>Filial (centro de custo)<select name="branch_id" defaultValue={v('branch_id')} className="field mt-1.5"><option value="">Empresa toda</option>{branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          <label className={label}>Competência <span className="font-normal text-muted">(DRE; vazio = vencimento)</span><input type="date" name="competence_on" defaultValue={v('competence_on')} className="field mt-1.5" /></label>
          <label className={label}>Documento<input name="document" maxLength={60} defaultValue={v('document')} className="field mt-1.5" /></label>
        </div>
      </details>
      <div className="flex justify-end sm:col-span-3"><SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Registrar</SubmitButton></div>
    </form>
  )
}
