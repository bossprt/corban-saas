'use client'

import { useState } from 'react'
import { Plus, X } from 'lucide-react'
import { ACCOUNT_TYPE_LABEL } from '@/lib/clients/profile'

const lbl = 'text-[13px] font-medium text-ink-soft'
const legend = 'mb-2 text-sm font-semibold text-ink'
const optional = 'ml-1 text-xs font-normal text-muted'
const addBtn = 'inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink hover:bg-surface-muted'
const removeBtn = 'inline-flex items-center gap-1 text-xs text-muted hover:text-[#991B1B]'

// Rows keep stable keys; every row posts the same field names, read on the server with getAll() in row order.
function useRows() {
  const [rows, setRows] = useState<number[]>([0])
  const [next, setNext] = useState(1)
  return {
    rows,
    add: () => { setRows(r => [...r, next]); setNext(n => n + 1) },
    remove: (k: number) => setRows(r => (r.length > 1 ? r.filter(x => x !== k) : r)),
  }
}

export function BankAccountRows() {
  const { rows, add, remove } = useRows()
  return (
    <fieldset>
      <legend className={legend}>4. Dados bancários <span className={optional}>opcional</span></legend>
      <div className="grid gap-4">
        {rows.map((k, i) => (
          <div key={k} className="grid gap-3 rounded-[12px] border border-line p-3 md:grid-cols-4" data-row="account">
            <div className="flex items-center justify-between md:col-span-4">
              <span className="text-xs font-semibold text-muted">Conta {i + 1}</span>
              <span className="flex items-center gap-3">
                <label className="flex items-center gap-1.5 text-xs text-ink"><input type="radio" name="primary_account" value={i} defaultChecked={i === 0} className="accent-[var(--brand)]" />Principal</label>
                {rows.length > 1 && <button type="button" onClick={() => remove(k)} className={removeBtn}><X size={13} aria-hidden />Remover</button>}
              </span>
            </div>
            <label className={lbl}>Código do banco<input name="bank_code" inputMode="numeric" maxLength={3} placeholder="001" className="field mt-1.5 font-mono" /></label>
            <label className={`${lbl} md:col-span-3`}>Banco<input name="bank_name" maxLength={120} placeholder="Banco do Brasil" className="field mt-1.5" /></label>
            <label className={lbl}>Agência<input name="branch" inputMode="numeric" maxLength={8} className="field mt-1.5 font-mono" /></label>
            <label className={lbl}>Conta<input name="account_number" inputMode="numeric" maxLength={20} className="field mt-1.5 font-mono" /></label>
            <label className={lbl}>Dígito<input name="account_digit" maxLength={2} className="field mt-1.5 font-mono" /></label>
            <label className={lbl}>Tipo<select name="account_type" className="field mt-1.5">{Object.entries(ACCOUNT_TYPE_LABEL).map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></label>
          </div>
        ))}
        <div><button type="button" onClick={add} className={addBtn}><Plus size={15} aria-hidden />Adicionar outra conta</button></div>
      </div>
    </fieldset>
  )
}

export function RegistrationRows({ agreements }: { agreements: { id: string; name: string }[] }) {
  const { rows, add, remove } = useRows()
  return (
    <fieldset>
      <legend className={legend}>5. Matrículas <span className={optional}>opcional</span></legend>
      <div className="grid gap-4">
        {rows.map((k, i) => (
          <div key={k} className="grid gap-3 rounded-[12px] border border-line p-3 md:grid-cols-4" data-row="registration">
            <div className="flex items-center justify-between md:col-span-4">
              <span className="text-xs font-semibold text-muted">Matrícula {i + 1}</span>
              {rows.length > 1 && <button type="button" onClick={() => remove(k)} className={removeBtn}><X size={13} aria-hidden />Remover</button>}
            </div>
            <label className={lbl}>Convênio<select name="agreement_id" defaultValue="" className="field mt-1.5"><option value="">—</option>{agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            <label className={lbl}>Órgão<input name="agency_name" maxLength={160} placeholder="Secretaria de Educação" className="field mt-1.5" /></label>
            <label className={lbl}>Matrícula<input name="registration_number" maxLength={40} className="field mt-1.5 font-mono" /></label>
            <label className={lbl}>Margem (R$)<input name="margin_amount" inputMode="decimal" placeholder="0,00" className="field mt-1.5" /></label>
            <label className={lbl}>ID / login<input name="portal_login" maxLength={120} autoComplete="off" className="field mt-1.5 font-mono" /></label>
            <label className={lbl}>Senha<input name="portal_password" type="password" maxLength={200} autoComplete="new-password" className="field mt-1.5 font-mono" /></label>
          </div>
        ))}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <button type="button" onClick={add} className={addBtn}><Plus size={15} aria-hidden />Adicionar outra matrícula</button>
          <p className="text-xs text-muted">As senhas ficam criptografadas no cofre; só aparecem no botão Mostrar senha, e cada visualização é registrada.</p>
        </div>
      </div>
    </fieldset>
  )
}
