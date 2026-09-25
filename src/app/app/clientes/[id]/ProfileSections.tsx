import { SubmitButton } from '@/components/SubmitButton'
import { Badge, Card, CardHeader } from '@/components/ui'
import { formatPhone } from '@/lib/cpf'
import { ACCOUNT_TYPE_LABEL, ageOn, dateBr, GENDER_LABEL, MARITAL_LABEL, UFS, type ProfileFields } from '@/lib/clients/profile'
import { brlText } from '@/lib/receipts/format'
import { addClientBankAccount, saveClientRegistration, setClientBankAccount, updateClientProfile } from '../actions'
import { RevealPassword } from './RevealPassword'

const label = 'text-[13px] font-medium text-ink-soft'
const btn = 'h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost = 'h-8 rounded-md border border-line px-2 text-xs text-ink-soft hover:bg-surface-muted'
const todayIso = () => new Date().toISOString().slice(0, 10)

export type BankAccount = { id: string; bank_code: string; bank_name: string; branch: string; account_number: string; account_digit: string | null; account_type: string; is_primary: boolean }
export type Registration = { id: string; agreement_id: string; agency_name: string | null; registration_number: string; status: string; margin_amount: string | null; margin_as_of: string | null;
  portal_login: string | null; has_portal_password: boolean; notes: string | null }

function Field({ name, value }: { name: string; value: React.ReactNode }) {
  return <div><dt className="text-xs text-muted">{name}</dt><dd className="text-sm text-ink">{value || '—'}</dd></div>
}

// Personal data: shown, and editable by who may edit clients (the database checks it again).
export function PersonalData({ clientId, phone, p, canEdit }: { clientId: string; phone: string | null; p: ProfileFields; canEdit: boolean }) {
  const age = p.birth_date ? ageOn(p.birth_date, todayIso()) : null
  return (
    <Card>
      <CardHeader title="Dados pessoais" />
      <dl className="grid grid-cols-2 gap-x-4 gap-y-3 px-5 pb-4 pt-3 sm:grid-cols-3">
        <Field name="Data de nascimento" value={p.birth_date ? `${dateBr(p.birth_date)} (${age} anos)` : null} />
        <Field name="Sexo" value={p.gender ? GENDER_LABEL[p.gender] : null} />
        <Field name="Estado civil" value={p.marital_status ? MARITAL_LABEL[p.marital_status] : null} />
        <Field name="Nome da mãe" value={p.mother_name} />
        <Field name="Nome do pai" value={p.father_name} />
        <Field name="Naturalidade" value={p.birthplace_city ? `${p.birthplace_city}${p.birthplace_state ? `/${p.birthplace_state}` : ''}` : null} />
        <Field name="RG" value={p.rg_number ? `${p.rg_number}${p.rg_issuer ? ` ${p.rg_issuer}` : ''}${p.rg_state ? `/${p.rg_state}` : ''}` : null} />
        <Field name="Emissão do RG" value={p.rg_issued_on ? dateBr(p.rg_issued_on) : null} />
        <Field name="WhatsApp" value={p.whatsapp ? formatPhone(p.whatsapp) : null} />
      </dl>
      {canEdit && (
        <details className="border-t border-line px-5 py-3">
          <summary className="cursor-pointer text-sm font-medium text-brand">Editar dados pessoais</summary>
          <form action={updateClientProfile} className="mt-3 grid gap-3 sm:grid-cols-3">
            <input type="hidden" name="client_id" value={clientId} />
            <input type="hidden" name="phone" value={phone ?? ''} />
            <label className={label}>Data de nascimento<input name="birth_date" type="date" defaultValue={p.birth_date ?? ''} max={todayIso()} className="field mt-1.5" /></label>
            <label className={label}>Sexo<select name="gender" defaultValue={p.gender ?? ''} className="field mt-1.5"><option value="">—</option>{Object.entries(GENDER_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className={label}>Estado civil<select name="marital_status" defaultValue={p.marital_status ?? ''} className="field mt-1.5"><option value="">—</option>{Object.entries(MARITAL_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className={`${label} sm:col-span-3`}>Nome da mãe<input name="mother_name" defaultValue={p.mother_name ?? ''} maxLength={160} className="field mt-1.5" /></label>
            <label className={`${label} sm:col-span-3`}>Nome do pai<input name="father_name" defaultValue={p.father_name ?? ''} maxLength={160} className="field mt-1.5" /></label>
            <label className={label}>RG<input name="rg_number" defaultValue={p.rg_number ?? ''} maxLength={20} className="field mt-1.5 font-mono" /></label>
            <label className={label}>Órgão expedidor<input name="rg_issuer" defaultValue={p.rg_issuer ?? ''} maxLength={20} placeholder="SSP" className="field mt-1.5" /></label>
            <label className={label}>UF do RG<select name="rg_state" defaultValue={p.rg_state ?? ''} className="field mt-1.5"><option value="">—</option>{UFS.map(u => <option key={u}>{u}</option>)}</select></label>
            <label className={label}>Data de emissão<input name="rg_issued_on" type="date" defaultValue={p.rg_issued_on ?? ''} max={todayIso()} className="field mt-1.5" /></label>
            <label className={label}>Naturalidade (cidade)<input name="birthplace_city" defaultValue={p.birthplace_city ?? ''} maxLength={120} className="field mt-1.5" /></label>
            <label className={label}>UF de nascimento<select name="birthplace_state" defaultValue={p.birthplace_state ?? ''} className="field mt-1.5"><option value="">—</option>{UFS.map(u => <option key={u}>{u}</option>)}</select></label>
            <label className={label}>WhatsApp<input name="whatsapp" inputMode="tel" defaultValue={p.whatsapp ? formatPhone(p.whatsapp) : ''} placeholder="(68) 99999-0000" className="field mt-1.5" /></label>
            <label className="flex items-end gap-2 pb-2.5 text-sm text-ink sm:col-span-2"><input type="checkbox" name="whatsapp_same" className="accent-[var(--brand)]" />Mesmo número do telefone</label>
            <div className="flex justify-end sm:col-span-3"><SubmitButton className={btn} pendingText="Salvando...">Salvar dados pessoais</SubmitButton></div>
          </form>
        </details>
      )}
    </Card>
  )
}

export function BankAccounts({ clientId, accounts, canEdit }: { clientId: string; accounts: BankAccount[]; canEdit: boolean }) {
  return (
    <Card>
      <CardHeader title="Dados bancários" />
      <ul className="mt-3 text-sm">
        {accounts.map(a => (
          <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 border-t border-line px-5 py-2.5">
            <span>
              <span className="font-medium text-ink">{a.bank_code} · {a.bank_name}</span>
              <span className="ml-2 font-mono text-[13px] text-ink-soft">ag. {a.branch} · {a.account_number}{a.account_digit ? `-${a.account_digit}` : ''}</span>
              <span className="ml-2 text-xs text-muted">{ACCOUNT_TYPE_LABEL[a.account_type] ?? a.account_type}</span>
              {a.is_primary && <Badge tone="brand" className="ml-2">Principal</Badge>}
            </span>
            {canEdit && (
              <span className="flex gap-1">
                {!a.is_primary && <form action={setClientBankAccount}><input type="hidden" name="client_id" value={clientId} /><input type="hidden" name="account_id" value={a.id} /><input type="hidden" name="action" value="primary" /><SubmitButton className={ghost}>Tornar principal</SubmitButton></form>}
                <form action={setClientBankAccount}><input type="hidden" name="client_id" value={clientId} /><input type="hidden" name="account_id" value={a.id} /><input type="hidden" name="action" value="remove" /><SubmitButton className={ghost}>Remover</SubmitButton></form>
              </span>
            )}
          </li>
        ))}
        {!accounts.length && <li className="border-t border-line px-5 py-3 text-muted">Nenhuma conta cadastrada.</li>}
      </ul>
      {canEdit && (
        <details className="border-t border-line px-5 py-3">
          <summary className="cursor-pointer text-sm font-medium text-brand">Adicionar conta</summary>
          <form action={addClientBankAccount} className="mt-3 grid gap-3 sm:grid-cols-4">
            <input type="hidden" name="client_id" value={clientId} />
            <label className={label}>Código do banco<input name="bank_code" required inputMode="numeric" maxLength={3} placeholder="001" className="field mt-1.5 font-mono" /></label>
            <label className={`${label} sm:col-span-3`}>Banco<input name="bank_name" required maxLength={120} placeholder="Banco do Brasil" className="field mt-1.5" /></label>
            <label className={label}>Agência<input name="branch" required inputMode="numeric" maxLength={8} className="field mt-1.5 font-mono" /></label>
            <label className={label}>Conta<input name="account_number" required inputMode="numeric" maxLength={20} className="field mt-1.5 font-mono" /></label>
            <label className={label}>Dígito<input name="account_digit" maxLength={2} className="field mt-1.5 font-mono" /></label>
            <label className={label}>Tipo<select name="account_type" className="field mt-1.5">{Object.entries(ACCOUNT_TYPE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className="flex items-center gap-2 text-sm text-ink sm:col-span-2"><input type="checkbox" name="is_primary" className="accent-[var(--brand)]" />Conta principal</label>
            <div className="flex justify-end sm:col-span-2"><SubmitButton className={btn} pendingText="Salvando...">Adicionar conta</SubmitButton></div>
          </form>
        </details>
      )}
    </Card>
  )
}

function RegistrationForm({ clientId, agreements, r }: { clientId: string; agreements: { id: string; name: string }[]; r?: Registration }) {
  return (
    <form action={saveClientRegistration} className="mt-3 grid gap-3 sm:grid-cols-3">
      <input type="hidden" name="client_id" value={clientId} />
      {r && <input type="hidden" name="registration_id" value={r.id} />}
      <label className={label}>Convênio
        <select name="agreement_id" required defaultValue={r?.agreement_id ?? ''} className="field mt-1.5">
          <option value="" disabled>Escolha</option>{agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
        </select>
      </label>
      <label className={label}>Órgão<input name="agency_name" defaultValue={r?.agency_name ?? ''} maxLength={160} placeholder="Secretaria de Educação" className="field mt-1.5" /></label>
      <label className={label}>Matrícula<input name="registration_number" required defaultValue={r?.registration_number ?? ''} maxLength={40} className="field mt-1.5 font-mono" /></label>
      <label className={label}>Margem (R$)<input name="margin_amount" inputMode="decimal" defaultValue={r?.margin_amount ? String(r.margin_amount).replace('.', ',') : ''} placeholder="0,00" className="field mt-1.5" /></label>
      <label className={label}>Margem consultada em<input name="margin_as_of" type="date" defaultValue={r?.margin_as_of ?? todayIso()} max={todayIso()} className="field mt-1.5" /></label>
      <label className={label}>Situação<select name="status" defaultValue={r?.status ?? 'active'} className="field mt-1.5"><option value="active">Ativa</option><option value="inactive">Inativa</option></select></label>
      <label className={label}>ID / login<input name="portal_login" defaultValue={r?.portal_login ?? ''} maxLength={120} autoComplete="off" className="field mt-1.5 font-mono" /></label>
      <label className={label}>{r?.has_portal_password ? 'Nova senha (vazio mantém a atual)' : 'Senha'}<input name="portal_password" type="password" maxLength={200} autoComplete="new-password" className="field mt-1.5 font-mono" /></label>
      {r?.has_portal_password
        ? <label className="flex items-end gap-2 pb-2.5 text-sm text-ink"><input type="checkbox" name="clear_password" className="accent-[var(--brand)]" />Apagar a senha guardada</label>
        : <span />}
      <label className={`${label} sm:col-span-3`}>Observação<input name="notes" defaultValue={r?.notes ?? ''} maxLength={300} className="field mt-1.5" /></label>
      <p className="text-xs text-muted sm:col-span-2">A senha fica criptografada no cofre; só aparece no botão Mostrar senha, e cada visualização é registrada.</p>
      <div className="flex justify-end"><SubmitButton className={btn} pendingText="Salvando...">{r ? 'Salvar matrícula' : 'Adicionar matrícula'}</SubmitButton></div>
    </form>
  )
}

export function Registrations({ clientId, registrations, agreements, canEdit }: { clientId: string; registrations: Registration[]; agreements: { id: string; name: string }[]; canEdit: boolean }) {
  const agreementName = new Map(agreements.map(a => [a.id, a.name]))
  return (
    <Card>
      <CardHeader title={<span className="flex items-center gap-2">Matrículas <Badge tone="neutral">{registrations.length}</Badge></span>} />
      <ul className="mt-3 text-sm">
        {registrations.map(r => (
          <li key={r.id} className="border-t border-line px-5 py-3">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span><span className="font-medium text-ink">{agreementName.get(r.agreement_id) ?? 'Convênio'}</span>{r.agency_name && <span className="text-ink-soft"> · {r.agency_name}</span>}</span>
              <Badge tone={r.status === 'active' ? 'received' : 'neutral'}>{r.status === 'active' ? 'Ativa' : 'Inativa'}</Badge>
            </div>
            <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4">
              <Field name="Matrícula" value={<span className="font-mono">{r.registration_number}</span>} />
              <Field name="Margem" value={r.margin_amount !== null ? <span className="num">{brlText(r.margin_amount)} <span className="text-xs text-muted">em {dateBr(r.margin_as_of)}</span></span> : null} />
              <Field name="ID / login" value={r.portal_login ? <span className="font-mono">{r.portal_login}</span> : null} />
              <Field name="Senha" value={r.has_portal_password ? (canEdit ? <RevealPassword registrationId={r.id} /> : '••••••••') : null} />
            </dl>
            {canEdit && <details className="mt-2"><summary className="cursor-pointer text-xs text-brand">Editar matrícula</summary><RegistrationForm clientId={clientId} agreements={agreements} r={r} /></details>}
          </li>
        ))}
        {!registrations.length && <li className="border-t border-line px-5 py-3 text-muted">Nenhuma matrícula cadastrada.</li>}
      </ul>
      {canEdit && (
        <details className="border-t border-line px-5 py-3">
          <summary className="cursor-pointer text-sm font-medium text-brand">Adicionar matrícula</summary>
          {agreements.length ? <RegistrationForm clientId={clientId} agreements={agreements} /> : <p className="mt-2 text-sm text-muted">Cadastre ou habilite um convênio em Comercial antes.</p>}
        </details>
      )}
    </Card>
  )
}
