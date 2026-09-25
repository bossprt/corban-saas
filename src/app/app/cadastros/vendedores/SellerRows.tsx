'use client'

import { useState } from 'react'
import { Plus, RotateCcw, X } from 'lucide-react'
import { ACCOUNT_TYPE_LABEL } from '@/lib/clients/profile'
import { formatTaxId, PIX_TYPE_LABEL } from '@/lib/sellers'

const lbl = 'text-[13px] font-medium text-ink-soft'
const legend = 'mb-2 text-sm font-semibold text-ink'
const optional = 'ml-1 text-xs font-normal text-muted'
const addBtn = 'inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink hover:bg-surface-muted'
const removeBtn = 'inline-flex items-center gap-1 text-xs text-muted hover:text-[#991B1B]'

export type SellerAccount = {
  id: string; transfer_method: string; account_type: string | null; bank_code: string | null; bank_name: string | null; branch: string | null
  account_number: string | null; account_digit: string | null; pix_key_type: string | null; pix_key: string | null
  holder_name: string | null; holder_document: string | null; note: string | null; is_primary: boolean
}
export type SellerContact = { name: string; cpf: string | null; role: string | null; mobile: string | null; email: string | null }

// Every row posts the same field names in order; the server reads them with getAll(). Hidden parts stay in the form
// (only visually hidden) so the lists never lose their alignment.
function useRows<T>(initial: T[], startEmpty: boolean) {
  const [rows, setRows] = useState<{ key: number; item?: T; removed: boolean }[]>(
    initial.length ? initial.map((item, i) => ({ key: i, item, removed: false })) : startEmpty ? [{ key: 0, removed: false }] : [])
  const [next, setNext] = useState(Math.max(initial.length, 1))
  return {
    rows,
    add: () => { setRows(r => [...r, { key: next, removed: false }]); setNext(n => n + 1) },
    drop: (key: number) => setRows(r => r.filter(x => x.key !== key)),
    toggle: (key: number) => setRows(r => r.map(x => (x.key === key ? { ...x, removed: !x.removed } : x))),
  }
}

function AccountRow({ a, index, primary, removed, locked, onRemove, canDrop }: {
  a?: SellerAccount; index: number; primary: boolean; removed: boolean; locked: boolean; onRemove?: () => void; canDrop: boolean
}) {
  const [method, setMethod] = useState(a?.transfer_method ?? 'pix')
  const [payee, setPayee] = useState(!!a?.holder_name)
  return (
    <div className={`grid gap-3 rounded-[12px] border border-line p-3 md:grid-cols-4 ${removed ? 'opacity-50' : ''}`} data-row="seller-account">
      <input type="hidden" name="account_id" value={a?.id ?? ''} />
      <input type="hidden" name="remove_account" value={removed ? '1' : ''} />
      <input type="hidden" name="has_payee" value={payee ? '1' : ''} />
      <div className="flex items-center justify-between md:col-span-4">
        <span className="text-xs font-semibold text-muted">Conta {index + 1}{removed && ' · será removida ao salvar'}</span>
        <span className="flex items-center gap-3">
          <label className="flex items-center gap-1.5 text-xs text-ink"><input type="radio" name="primary_account" value={index} defaultChecked={primary} className="accent-[var(--brand)]" />Principal</label>
          {!locked && (a
            ? <button type="button" onClick={onRemove} className={removeBtn}>{removed ? <><RotateCcw size={13} aria-hidden />Manter</> : <><X size={13} aria-hidden />Remover</>}</button>
            : canDrop && <button type="button" onClick={onRemove} className={removeBtn}><X size={13} aria-hidden />Remover</button>)}
        </span>
      </div>
      <label className={lbl}>Forma de pagamento
        <select name="transfer_method" value={method} onChange={e => setMethod(e.target.value)} className="field mt-1.5"><option value="pix">PIX</option><option value="ted">TED</option></select>
      </label>
      <div className={method === 'pix' ? 'contents' : 'hidden'}>
        <label className={lbl}>Tipo de chave PIX
          <select name="pix_key_type" defaultValue={a?.pix_key_type ?? 'cpf_cnpj'} className="field mt-1.5">{Object.entries(PIX_TYPE_LABEL).map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select>
        </label>
        <label className={`${lbl} md:col-span-2`}>Chave PIX<input name="pix_key" defaultValue={a?.pix_key ?? ''} maxLength={77} autoComplete="off" className="field mt-1.5 font-mono" /></label>
      </div>
      <div className={method === 'ted' ? 'contents' : 'hidden'}>
        <label className={lbl}>Tipo de conta
          <select name="account_type" defaultValue={a?.account_type ?? 'checking'} className="field mt-1.5">{Object.entries(ACCOUNT_TYPE_LABEL).map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select>
        </label>
        <label className={lbl}>Código do banco<input name="bank_code" defaultValue={a?.bank_code ?? ''} inputMode="numeric" maxLength={3} placeholder="001" className="field mt-1.5 font-mono" /></label>
        <label className={lbl}>Banco<input name="bank_name" defaultValue={a?.bank_name ?? ''} maxLength={120} className="field mt-1.5" /></label>
        <label className={lbl}>Agência<input name="branch" defaultValue={a?.branch ?? ''} inputMode="numeric" maxLength={8} className="field mt-1.5 font-mono" /></label>
        <label className={lbl}>Conta<input name="account_number" defaultValue={a?.account_number ?? ''} inputMode="numeric" maxLength={20} className="field mt-1.5 font-mono" /></label>
        <label className={lbl}>Dígito<input name="account_digit" defaultValue={a?.account_digit ?? ''} maxLength={2} className="field mt-1.5 font-mono" /></label>
      </div>
      <label className="flex items-center gap-2 text-sm text-ink md:col-span-4">
        <input type="checkbox" checked={payee} onChange={e => setPayee(e.target.checked)} className="accent-[var(--brand)]" />
        O dinheiro vai para outra pessoa ou empresa (favorecido)
      </label>
      <div className={payee ? 'contents' : 'hidden'}>
        <label className={`${lbl} md:col-span-2`}>Nome do favorecido<input name="holder_name" defaultValue={a?.holder_name ?? ''} maxLength={160} className="field mt-1.5" /></label>
        <label className={lbl}>CPF/CNPJ do favorecido<input name="holder_document" defaultValue={formatTaxId(a?.holder_document)} inputMode="numeric" className="field mt-1.5 font-mono" /></label>
      </div>
      <label className={`${lbl} md:col-span-4`}>Observação <span className="font-normal text-muted">opcional</span><input name="account_note" defaultValue={a?.note ?? ''} maxLength={800} className="field mt-1.5" /></label>
    </div>
  )
}

export function SellerAccountRows({ initial, locked, visible }: { initial: SellerAccount[]; locked: boolean; visible: boolean }) {
  const { rows, add, drop, toggle } = useRows(initial, true)
  const primaryIndex = Math.max(0, rows.findIndex(r => r.item?.is_primary))
  if (!visible) return null
  return (
    <fieldset>
      <legend className={legend}>4. Dados para pagamento da comissão <span className={optional}>opcional</span></legend>
      <input type="hidden" name="accounts_included" value="1" />
      <div className="grid gap-4">
        {locked && !initial.length && <p className="text-sm text-muted">Nenhuma conta cadastrada.</p>}
        {!(locked && !initial.length) && rows.map((r, i) => (
          <AccountRow key={r.key} a={r.item} index={i} primary={i === primaryIndex} removed={r.removed} locked={locked}
            onRemove={() => (r.item ? toggle(r.key) : drop(r.key))} canDrop={rows.length > 1} />
        ))}
        {!locked && <div><button type="button" onClick={add} className={addBtn}><Plus size={15} aria-hidden />Adicionar outra conta</button></div>}
      </div>
    </fieldset>
  )
}

export function SellerContactRows({ initial, locked }: { initial: SellerContact[]; locked: boolean }) {
  const { rows, add, drop } = useRows(initial, false)
  return (
    <fieldset>
      <legend className={legend}>5. Contatos da empresa do vendedor <span className={optional}>opcional (sócio, escritório...)</span></legend>
      <div className="grid gap-4">
        {rows.map((r, i) => {
          const c = r.item
          return (
            <div key={r.key} className="grid gap-3 rounded-[12px] border border-line p-3 md:grid-cols-4" data-row="seller-contact">
              <div className="flex items-center justify-between md:col-span-4">
                <span className="text-xs font-semibold text-muted">Contato {i + 1}</span>
                {!locked && <button type="button" onClick={() => drop(r.key)} className={removeBtn}><X size={13} aria-hidden />Remover</button>}
              </div>
              <label className={`${lbl} md:col-span-2`}>Nome<input name="contact_name" defaultValue={c?.name ?? ''} maxLength={160} className="field mt-1.5" /></label>
              <label className={lbl}>CPF<input name="contact_cpf" defaultValue={c?.cpf ?? ''} inputMode="numeric" className="field mt-1.5 font-mono" /></label>
              <label className={lbl}>Cargo<input name="contact_role" defaultValue={c?.role ?? ''} maxLength={80} placeholder="Sócio, financeiro..." className="field mt-1.5" /></label>
              <label className={lbl}>Celular<input name="contact_mobile" defaultValue={c?.mobile ?? ''} inputMode="tel" className="field mt-1.5" /></label>
              <label className={`${lbl} md:col-span-2`}>E-mail<input name="contact_email" type="email" defaultValue={c?.email ?? ''} maxLength={160} className="field mt-1.5" /></label>
            </div>
          )
        })}
        {!locked && <div><button type="button" onClick={add} className={addBtn}><Plus size={15} aria-hidden />Adicionar contato</button></div>}
        {locked && !rows.length && <p className="text-sm text-muted">Nenhum contato cadastrado.</p>}
      </div>
    </fieldset>
  )
}
