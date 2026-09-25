'use client'

import { useState } from 'react'
import { Pencil, X } from 'lucide-react'
import { AddressFields } from '@/components/AddressFields'
import { SubmitButton } from '@/components/SubmitButton'
import { formatPhone } from '@/lib/cpf'
import { formatTaxId } from '@/lib/sellers'
import { SellerAccountRows, SellerContactRows, type SellerAccount, type SellerContact } from './SellerRows'

const lbl = 'text-[13px] font-medium text-ink-soft'
const legend = 'mb-2 text-sm font-semibold text-ink'
const optional = 'ml-1 text-xs font-normal text-muted'
const req = <span className="text-[#991B1B]" aria-hidden> *</span>

export type SellerValues = {
  id: string; code: number; name: string; tax_id: string | null; seller_category: string; commission_group_id: string; branch_id: string | null
  trade_name: string | null; birth_or_opening_date: string | null; identity_or_registration_number: string | null; identity_issuer: string | null
  rg_issued_on: string | null; mother_name: string | null; father_name: string | null; phone: string | null; whatsapp: string | null
  other_phones: string | null; email: string | null
  zip: string | null; street: string | null; number: string | null; complement: string | null; district: string | null; city: string | null; state: string | null
  business_zip: string | null; business_street: string | null; business_number: string | null; business_complement: string | null
  business_district: string | null; business_city: string | null; business_state: string | null
}

const address = (v: SellerValues | undefined, p: '' | 'business_') => v && {
  zip: v[`${p}zip`] ?? '', street: v[`${p}street`] ?? '', number: v[`${p}number`] ?? '', complement: v[`${p}complement`] ?? '',
  district: v[`${p}district`] ?? '', city: v[`${p}city`] ?? '', state: v[`${p}state`] ?? '',
}

// One form for registering and for the seller file (owner decision 25/09/2026). An existing seller opens locked;
// "Editar cadastro" unlocks it in place. Only name, CPF/CNPJ, mobile and e-mail are required.
export function SellerForm({ action, seller, accounts = [], contacts = [], groups, branches, canEdit, canSeeBank }: {
  action: (f: FormData) => Promise<void>
  seller?: SellerValues
  accounts?: SellerAccount[]; contacts?: SellerContact[]
  groups: { id: string; name: string }[]; branches: { id: string; name: string }[]
  canEdit: boolean; canSeeBank: boolean
}) {
  const s = seller
  const [editing, setEditing] = useState(!s)
  const [round, setRound] = useState(0)
  const locked = !editing
  const hasBusiness = !!s?.business_zip || !!s?.business_street
  return (
    <form action={action} className="grid gap-6">
      {s && <input type="hidden" name="seller_id" value={s.id} />}
      {s && canEdit && (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-muted">{locked ? 'Para alterar, clique em Editar cadastro.' : 'Editando: altere o que precisar e clique em Salvar alterações.'}</p>
          {locked
            ? <button type="button" onClick={() => setEditing(true)} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm font-medium text-ink hover:bg-surface-muted"><Pencil size={15} aria-hidden />Editar cadastro</button>
            : <button type="button" onClick={() => { setEditing(false); setRound(r => r + 1) }} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink-soft hover:bg-surface-muted"><X size={15} aria-hidden />Cancelar</button>}
        </div>
      )}
      <fieldset key={round} disabled={locked} className="grid gap-6">
        <fieldset className="grid gap-3 md:grid-cols-4">
          <legend className={legend}>1. Dados básicos</legend>
          {s && <div className={lbl}>Código<div className="field mt-1.5 flex items-center bg-surface-muted font-mono text-ink-soft" title="Número automático, não muda">{String(s.code).padStart(3, '0')}</div></div>}
          <label className={`${lbl} ${s ? 'md:col-span-2' : 'md:col-span-3'}`}>Nome / razão social{req}<input required name="name" maxLength={160} defaultValue={s?.name ?? ''} className="field mt-1.5" autoComplete="off" /></label>
          <label className={lbl}>CPF/CNPJ{req}<input required name="tax_id" defaultValue={formatTaxId(s?.tax_id)} inputMode="numeric" className="field mt-1.5 font-mono" autoComplete="off" /></label>
          <label className={lbl}>Categoria{req}<select required name="seller_category" defaultValue={s?.seller_category ?? ''} className="field mt-1.5"><option value="" disabled>—</option><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select></label>
          <label className={lbl}>Grupo{req}<select required name="commission_group_id" defaultValue={s?.commission_group_id ?? ''} className="field mt-1.5"><option value="" disabled>Escolha o grupo</option>{groups.map(g => <option key={g.id} value={g.id}>{g.name}</option>)}</select></label>
          <label className={lbl}>Filial<select name="branch_id" defaultValue={s?.branch_id ?? ''} className="field mt-1.5"><option value="">Matriz (padrão)</option>{branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          <label className={lbl}>Nome fantasia <span className="font-normal text-muted">se PJ</span><input name="trade_name" maxLength={160} defaultValue={s?.trade_name ?? ''} className="field mt-1.5" /></label>
          <label className={lbl}>Nascimento / abertura<input name="birth_date" type="date" defaultValue={s?.birth_or_opening_date ?? ''} className="field mt-1.5" /></label>
          <label className={lbl}>RG<input name="rg" maxLength={20} defaultValue={s?.identity_or_registration_number ?? ''} className="field mt-1.5 font-mono" /></label>
          <label className={lbl}>Órgão emissor<input name="rg_issuer" maxLength={20} defaultValue={s?.identity_issuer ?? ''} placeholder="SSP/AC" className="field mt-1.5" /></label>
          <label className={lbl}>Data de emissão<input name="rg_issued_on" type="date" defaultValue={s?.rg_issued_on ?? ''} className="field mt-1.5" /></label>
          <label className={`${lbl} md:col-span-2`}>Nome da mãe<input name="mother_name" maxLength={160} defaultValue={s?.mother_name ?? ''} className="field mt-1.5" /></label>
          <label className={`${lbl} md:col-span-2`}>Nome do pai<input name="father_name" maxLength={160} defaultValue={s?.father_name ?? ''} className="field mt-1.5" /></label>
        </fieldset>

        <fieldset className="grid gap-3 md:grid-cols-4">
          <legend className={legend}>2. Contato</legend>
          <label className={lbl}>Celular{req}<input required name="mobile" defaultValue={s?.phone ? formatPhone(s.phone) : ''} inputMode="tel" placeholder="(68) 99900-0000" className="field mt-1.5" /></label>
          <label className={lbl}>WhatsApp<input name="whatsapp" defaultValue={s?.whatsapp ? formatPhone(s.whatsapp) : ''} inputMode="tel" className="field mt-1.5" /></label>
          <label className="flex items-end gap-2 pb-2.5 text-sm text-ink"><input type="checkbox" name="whatsapp_same" className="accent-[var(--brand)]" />Usar o celular no WhatsApp</label>
          <label className={lbl}>E-mail{req}<input required name="email" type="email" maxLength={160} defaultValue={s?.email ?? ''} className="field mt-1.5" /></label>
          <label className={`${lbl} md:col-span-4`}>Outros telefones <span className="font-normal text-muted">opcional</span><input name="other_phones" maxLength={160} defaultValue={s?.other_phones ?? ''} className="field mt-1.5" /></label>
        </fieldset>

        <fieldset>
          <legend className={legend}>3. Endereço <span className={optional}>opcional</span></legend>
          <div className="grid gap-3 md:grid-cols-5"><AddressFields initial={address(s, '')} legend="Endereço residencial" /></div>
          <details className="mt-3" open={hasBusiness}>
            <summary className="cursor-pointer text-sm text-brand">Endereço comercial</summary>
            <div className="mt-2 grid gap-3 md:grid-cols-5"><AddressFields initial={address(s, 'business_')} prefix="business_" legend="Endereço comercial" /></div>
          </details>
        </fieldset>

        <SellerAccountRows initial={accounts} locked={locked} visible={canSeeBank} />
        <SellerContactRows initial={contacts} locked={locked} />
      </fieldset>
      {editing && (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-muted">Obrigatórios: nome, CPF/CNPJ, categoria, grupo, celular e e-mail. O resto pode ser completado depois.</p>
          <SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">{s ? 'Salvar alterações' : 'Cadastrar vendedor'}</SubmitButton>
        </div>
      )}
    </form>
  )
}

