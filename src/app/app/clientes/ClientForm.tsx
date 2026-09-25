'use client'

import { useState } from 'react'
import { Pencil, X } from 'lucide-react'
import { AddressFields } from '@/components/AddressFields'
import { SubmitButton } from '@/components/SubmitButton'
import { formatCpf, formatPhone } from '@/lib/cpf'
import { GENDER_LABEL, MARITAL_LABEL, UFS, type ProfileFields } from '@/lib/clients/profile'
import { BankAccountRows, RegistrationRows, type AccountRow, type RegistrationRow } from './RepeatableBlocks'

const lbl = 'text-[13px] font-medium text-ink-soft'
const legend = 'mb-2 text-sm font-semibold text-ink'
const optional = 'ml-1 text-xs font-normal text-muted'

export type ClientFormValues = Partial<ProfileFields> & { id: string; full_name: string; cpf: string; phone: string | null; email: string | null }
export type AddressValues = { zip: string; street: string; number: string; complement: string; district: string; city: string; state: string }

// One form for registering and for editing a client (owner decision): the same five blocks, prefilled when editing.
// On the client page the form opens locked (the page itself is the client file); "Editar cadastro" unlocks it in place.
export function ClientForm({ mode, action, client, address, accounts = [], registrations = [], agreements, canEdit, canReveal = false }: {
  mode: 'create' | 'edit'; action: (f: FormData) => Promise<void>; client?: ClientFormValues; address?: AddressValues
  accounts?: AccountRow[]; registrations?: RegistrationRow[]; agreements: { id: string; name: string }[]; canEdit: boolean; canReveal?: boolean
}) {
  const c = client
  const [editing, setEditing] = useState(mode === 'create')
  const [round, setRound] = useState(0)
  const locked = !editing
  return (
    <form action={action} className="grid gap-5">
      {c && <input type="hidden" name="client_id" value={c.id} />}
      {mode === 'edit' && (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-muted">{locked ? 'Para alterar, clique em Editar cadastro.' : 'Editando: altere o que precisar e clique em Salvar alterações.'}</p>
          {locked
            ? <button type="button" onClick={() => setEditing(true)} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm font-medium text-ink hover:bg-surface-muted"><Pencil size={15} aria-hidden />Editar cadastro</button>
            : <button type="button" onClick={() => { setEditing(false); setRound(r => r + 1) }} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink-soft hover:bg-surface-muted"><X size={15} aria-hidden />Cancelar</button>}
        </div>
      )}
      <fieldset key={round} disabled={locked} className="grid gap-5">
      <fieldset className="grid gap-3 md:grid-cols-4">
        <legend className={legend}>1. Identificação</legend>
        <label className={`${lbl} md:col-span-2`}>Nome completo<input required minLength={3} maxLength={160} name="full_name" defaultValue={c?.full_name ?? ''} className="field mt-1.5" autoComplete="off" /></label>
        {mode === 'create'
          ? <label className={lbl}>CPF<input required name="cpf" inputMode="numeric" placeholder="000.000.000-00" className="field mt-1.5 font-mono" autoComplete="off" /></label>
          : <div className={lbl}>CPF<div className="field mt-1.5 flex items-center bg-surface-muted font-mono text-ink-soft" title="O CPF identifica o cliente e não muda">{formatCpf(c?.cpf)}</div></div>}
        <label className={lbl}>Telefone<input name="phone" defaultValue={c?.phone ? formatPhone(c.phone) : ''} inputMode="tel" placeholder="(68) 99900-0000" className="field mt-1.5" autoComplete="off" /></label>
        <label className={lbl}>WhatsApp<input name="whatsapp" defaultValue={c?.whatsapp ? formatPhone(c.whatsapp) : ''} inputMode="tel" placeholder="(68) 99900-0000" className="field mt-1.5" autoComplete="off" /></label>
        <label className="flex items-end gap-2 pb-2.5 text-sm text-ink"><input type="checkbox" name="whatsapp_same" className="accent-[var(--brand)]" />Usar o mesmo número no WhatsApp</label>
        <label className={lbl}>E-mail<input name="email" type="email" defaultValue={c?.email ?? ''} className="field mt-1.5" autoComplete="off" /></label>
        <label className={lbl}>Data de nascimento<input name="birth_date" type="date" defaultValue={c?.birth_date ?? ''} className="field mt-1.5" /></label>
      </fieldset>
      <fieldset>
        <legend className={legend}>2. Endereço <span className={optional}>opcional</span></legend>
        <div className="grid gap-3 md:grid-cols-5"><AddressFields initial={address} /></div>
      </fieldset>
      {canEdit && (
        <>
          <fieldset className="grid gap-3 md:grid-cols-4">
            <legend className={legend}>3. Dados pessoais <span className={optional}>opcional</span></legend>
            <label className={`${lbl} md:col-span-2`}>Nome da mãe<input name="mother_name" defaultValue={c?.mother_name ?? ''} maxLength={160} className="field mt-1.5" /></label>
            <label className={`${lbl} md:col-span-2`}>Nome do pai<input name="father_name" defaultValue={c?.father_name ?? ''} maxLength={160} className="field mt-1.5" /></label>
            <label className={lbl}>RG<input name="rg_number" defaultValue={c?.rg_number ?? ''} maxLength={20} className="field mt-1.5 font-mono" /></label>
            <label className={lbl}>Órgão expedidor<input name="rg_issuer" defaultValue={c?.rg_issuer ?? ''} maxLength={20} placeholder="SSP" className="field mt-1.5" /></label>
            <label className={lbl}>UF do RG<select name="rg_state" defaultValue={c?.rg_state ?? ''} className="field mt-1.5"><option value="">—</option>{UFS.map(u => <option key={u}>{u}</option>)}</select></label>
            <label className={lbl}>Data de emissão<input name="rg_issued_on" type="date" defaultValue={c?.rg_issued_on ?? ''} className="field mt-1.5" /></label>
            <label className={lbl}>Sexo<select name="gender" defaultValue={c?.gender ?? ''} className="field mt-1.5"><option value="">—</option>{Object.entries(GENDER_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className={lbl}>Estado civil<select name="marital_status" defaultValue={c?.marital_status ?? ''} className="field mt-1.5"><option value="">—</option>{Object.entries(MARITAL_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className={lbl}>Naturalidade (cidade)<input name="birthplace_city" defaultValue={c?.birthplace_city ?? ''} maxLength={120} className="field mt-1.5" /></label>
            <label className={lbl}>UF de nascimento<select name="birthplace_state" defaultValue={c?.birthplace_state ?? ''} className="field mt-1.5"><option value="">—</option>{UFS.map(u => <option key={u}>{u}</option>)}</select></label>
          </fieldset>
          <BankAccountRows initial={accounts} locked={locked} />
          <RegistrationRows agreements={agreements} initial={registrations} locked={locked} canReveal={canReveal} />
        </>
      )}
      </fieldset>
      {editing && <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-xs text-muted">{mode === 'create'
          ? 'Só nome, CPF e telefone são obrigatórios. CPF que já é cliente: os dados vazios são completados, nada é apagado.'
          : 'Telefone ou e-mail novo vira o principal; o anterior fica no histórico de contatos.'}</p>
        <SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">{mode === 'create' ? 'Cadastrar cliente' : 'Salvar alterações'}</SubmitButton>
      </div>}
    </form>
  )
}
