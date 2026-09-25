'use client'

import { useState } from 'react'
import { Plus, RotateCcw, X } from 'lucide-react'
import { ACCOUNT_TYPE_LABEL } from '@/lib/clients/profile'
import { RevealPassword } from './[id]/RevealPassword'

const lbl = 'text-[13px] font-medium text-ink-soft'
const legend = 'mb-2 text-sm font-semibold text-ink'
const optional = 'ml-1 text-xs font-normal text-muted'
const addBtn = 'inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink hover:bg-surface-muted'
const removeBtn = 'inline-flex items-center gap-1 text-xs text-muted hover:text-[#991B1B]'
const todayIso = () => new Date().toISOString().slice(0, 10)
// Database numeric ("350" or "812.45") to the form's "350,00" / "812,45", on the text: money never goes through float.
const marginText = (v: string | null | undefined) => {
  if (v === null || v === undefined || v === '') return ''
  const [int, dec = ''] = String(v).split('.')
  return `${int},${(dec + '00').slice(0, 2)}`
}

export type AccountRow = { id: string; bank_code: string; bank_name: string; branch: string; account_number: string; account_digit: string | null; account_type: string; is_primary: boolean }
export type RegistrationRow = { id: string; agreement_id: string; agency_name: string | null; registration_number: string; status: string; margin_amount: string | null; margin_as_of: string | null;
  portal_login: string | null; has_portal_password: boolean }

// Rows keep stable keys; every row posts the same field names, read on the server with getAll() in row order.
// Existing rows (edit) carry their id and are never dropped from the form: "Remover" only marks them.
function useRows<T>(initial: T[]) {
  const [rows, setRows] = useState<{ key: number; item?: T; removed: boolean }[]>(
    initial.length ? initial.map((item, i) => ({ key: i, item, removed: false })) : [{ key: 0, removed: false }])
  const [next, setNext] = useState(initial.length || 1)
  return {
    rows,
    add: () => { setRows(r => [...r, { key: next, removed: false }]); setNext(n => n + 1) },
    drop: (key: number) => setRows(r => r.filter(x => x.key !== key)),
    toggle: (key: number) => setRows(r => r.map(x => (x.key === key ? { ...x, removed: !x.removed } : x))),
  }
}

export function BankAccountRows({ initial = [], locked = false }: { initial?: AccountRow[]; locked?: boolean }) {
  const { rows, add, drop, toggle } = useRows(initial)
  const primaryIndex = Math.max(0, rows.findIndex(r => r.item?.is_primary))
  return (
    <fieldset>
      <legend className={legend}>4. Dados bancários <span className={optional}>opcional</span></legend>
      <div className="grid gap-4">
        {rows.map((r, i) => {
          const a = r.item
          return (
            <div key={r.key} className={`grid gap-3 rounded-[12px] border border-line p-3 md:grid-cols-4 ${r.removed ? 'opacity-50' : ''}`} data-row="account">
              <input type="hidden" name="account_id" value={a?.id ?? ''} />
              <input type="hidden" name="remove_account" value={r.removed ? '1' : ''} />
              <div className="flex items-center justify-between md:col-span-4">
                <span className="text-xs font-semibold text-muted">Conta {i + 1}{r.removed && ' · será removida ao salvar'}</span>
                <span className="flex items-center gap-3">
                  <label className="flex items-center gap-1.5 text-xs text-ink"><input type="radio" name="primary_account" value={i} defaultChecked={i === primaryIndex} className="accent-[var(--brand)]" />Principal</label>
                  {locked ? null : a
                    ? <button type="button" onClick={() => toggle(r.key)} className={removeBtn}>{r.removed ? <><RotateCcw size={13} aria-hidden />Manter</> : <><X size={13} aria-hidden />Remover</>}</button>
                    : rows.length > 1 && <button type="button" onClick={() => drop(r.key)} className={removeBtn}><X size={13} aria-hidden />Remover</button>}
                </span>
              </div>
              <label className={lbl}>Código do banco<input name="bank_code" defaultValue={a?.bank_code ?? ''} inputMode="numeric" maxLength={3} placeholder="001" className="field mt-1.5 font-mono" /></label>
              <label className={`${lbl} md:col-span-3`}>Banco<input name="bank_name" defaultValue={a?.bank_name ?? ''} maxLength={120} placeholder="Banco do Brasil" className="field mt-1.5" /></label>
              <label className={lbl}>Agência<input name="branch" defaultValue={a?.branch ?? ''} inputMode="numeric" maxLength={8} className="field mt-1.5 font-mono" /></label>
              <label className={lbl}>Conta<input name="account_number" defaultValue={a?.account_number ?? ''} inputMode="numeric" maxLength={20} className="field mt-1.5 font-mono" /></label>
              <label className={lbl}>Dígito<input name="account_digit" defaultValue={a?.account_digit ?? ''} maxLength={2} className="field mt-1.5 font-mono" /></label>
              <label className={lbl}>Tipo<select name="account_type" defaultValue={a?.account_type ?? 'checking'} className="field mt-1.5">{Object.entries(ACCOUNT_TYPE_LABEL).map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></label>
            </div>
          )
        })}
        {!locked && <div><button type="button" onClick={add} className={addBtn}><Plus size={15} aria-hidden />Adicionar outra conta</button></div>}
      </div>
    </fieldset>
  )
}

export function RegistrationRows({ agreements, initial = [], locked = false, canReveal = false }: { agreements: { id: string; name: string }[]; initial?: RegistrationRow[]; locked?: boolean; canReveal?: boolean }) {
  const { rows, add, drop, toggle } = useRows(initial)
  return (
    <fieldset>
      <legend className={legend}>5. Matrículas <span className={optional}>opcional</span></legend>
      <div className="grid gap-4">
        {rows.map((r, i) => {
          const m = r.item
          return (
            <div key={r.key} className="grid gap-3 rounded-[12px] border border-line p-3 md:grid-cols-4" data-row="registration">
              <input type="hidden" name="registration_id" value={m?.id ?? ''} />
              <input type="hidden" name="clear_password" value={r.removed ? '1' : ''} />
              <div className="flex items-center justify-between md:col-span-4">
                <span className="text-xs font-semibold text-muted">Matrícula {i + 1}</span>
                {!locked && !m && rows.length > 1 && <button type="button" onClick={() => drop(r.key)} className={removeBtn}><X size={13} aria-hidden />Remover</button>}
              </div>
              <label className={lbl}>Convênio<select name="agreement_id" defaultValue={m?.agreement_id ?? ''} className="field mt-1.5"><option value="">—</option>{agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
              <label className={lbl}>Órgão<input name="agency_name" defaultValue={m?.agency_name ?? ''} maxLength={160} placeholder="Secretaria de Educação" className="field mt-1.5" /></label>
              <label className={lbl}>Matrícula<input name="registration_number" defaultValue={m?.registration_number ?? ''} maxLength={40} className="field mt-1.5 font-mono" /></label>
              <label className={lbl}>Situação<select name="registration_status" defaultValue={m?.status ?? 'active'} className="field mt-1.5"><option value="active">Ativa</option><option value="inactive">Inativa</option></select></label>
              <label className={lbl}>Margem (R$)<input name="margin_amount" defaultValue={marginText(m?.margin_amount)} inputMode="decimal" placeholder="0,00" className="field mt-1.5" /></label>
              <label className={lbl}>Margem consultada em<input name="margin_as_of" type="date" defaultValue={m?.margin_as_of ?? todayIso()} max={todayIso()} className="field mt-1.5" /></label>
              <label className={lbl}>ID / login<input name="portal_login" defaultValue={m?.portal_login ?? ''} maxLength={120} autoComplete="off" className="field mt-1.5 font-mono" /></label>
              {locked && m
                ? <div className={lbl}>Senha<div className="mt-1.5 flex min-h-[42px] items-center">{m.has_portal_password ? (canReveal ? <RevealPassword registrationId={m.id} /> : <span className="font-mono text-[13px] text-muted">••••••••</span>) : <span className="text-sm text-muted">—</span>}</div></div>
                : <label className={lbl}>{m?.has_portal_password ? 'Nova senha (vazio mantém)' : 'Senha'}<input name="portal_password" type="password" maxLength={200} autoComplete="new-password" className="field mt-1.5 font-mono" /></label>}
              {!locked && m?.has_portal_password && (
                <label className="flex items-center gap-2 text-xs text-ink md:col-span-4">
                  <input type="checkbox" checked={r.removed} onChange={() => toggle(r.key)} className="accent-[var(--brand)]" />Apagar a senha guardada
                </label>
              )}
            </div>
          )
        })}
        <div className="flex flex-wrap items-center justify-between gap-3">
          {locked ? <span /> : <button type="button" onClick={add} className={addBtn}><Plus size={15} aria-hidden />Adicionar outra matrícula</button>}
          <p className="text-xs text-muted">As senhas ficam criptografadas no cofre; só aparecem no botão Mostrar senha, e cada visualização é registrada.</p>
        </div>
      </div>
    </fieldset>
  )
}
