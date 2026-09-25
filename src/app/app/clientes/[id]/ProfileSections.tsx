import { Badge, Card, CardHeader } from '@/components/ui'
import { formatPhone } from '@/lib/cpf'
import { ACCOUNT_TYPE_LABEL, ageOn, dateBr, GENDER_LABEL, MARITAL_LABEL, type ProfileFields } from '@/lib/clients/profile'
import { brlText } from '@/lib/receipts/format'
import { RevealPassword } from './RevealPassword'

// Read-only blocks of the client page. Editing happens in the same form as the registration (/app/clientes/[id]/editar).
const todayIso = () => new Date().toISOString().slice(0, 10)

export type BankAccount = { id: string; bank_code: string; bank_name: string; branch: string; account_number: string; account_digit: string | null; account_type: string; is_primary: boolean }
export type Registration = { id: string; agreement_id: string; agency_name: string | null; registration_number: string; status: string; margin_amount: string | null; margin_as_of: string | null;
  portal_login: string | null; has_portal_password: boolean; notes: string | null }

function Field({ name, value }: { name: string; value: React.ReactNode }) {
  return <div><dt className="text-xs text-muted">{name}</dt><dd className="text-sm text-ink">{value || '—'}</dd></div>
}

export function PersonalData({ p }: { p: ProfileFields }) {
  return (
    <Card>
      <CardHeader title="Dados pessoais" />
      <dl className="grid grid-cols-2 gap-x-4 gap-y-3 px-5 pb-5 pt-3 sm:grid-cols-3">
        <Field name="Data de nascimento" value={p.birth_date ? `${dateBr(p.birth_date)} (${ageOn(p.birth_date, todayIso())} anos)` : null} />
        <Field name="Sexo" value={p.gender ? GENDER_LABEL[p.gender] : null} />
        <Field name="Estado civil" value={p.marital_status ? MARITAL_LABEL[p.marital_status] : null} />
        <Field name="Nome da mãe" value={p.mother_name} />
        <Field name="Nome do pai" value={p.father_name} />
        <Field name="Naturalidade" value={p.birthplace_city ? `${p.birthplace_city}${p.birthplace_state ? `/${p.birthplace_state}` : ''}` : null} />
        <Field name="RG" value={p.rg_number ? `${p.rg_number}${p.rg_issuer ? ` ${p.rg_issuer}` : ''}${p.rg_state ? `/${p.rg_state}` : ''}` : null} />
        <Field name="Emissão do RG" value={p.rg_issued_on ? dateBr(p.rg_issued_on) : null} />
        <Field name="WhatsApp" value={p.whatsapp ? formatPhone(p.whatsapp) : null} />
      </dl>
    </Card>
  )
}

export function BankAccounts({ accounts }: { accounts: BankAccount[] }) {
  return (
    <Card>
      <CardHeader title="Dados bancários" />
      <ul className="mt-3 text-sm">
        {accounts.map(a => (
          <li key={a.id} className="flex flex-wrap items-center gap-2 border-t border-line px-5 py-2.5">
            <span className="font-medium text-ink">{a.bank_code} · {a.bank_name}</span>
            <span className="font-mono text-[13px] text-ink-soft">ag. {a.branch} · {a.account_number}{a.account_digit ? `-${a.account_digit}` : ''}</span>
            <span className="text-xs text-muted">{ACCOUNT_TYPE_LABEL[a.account_type] ?? a.account_type}</span>
            {a.is_primary && <Badge tone="brand">Principal</Badge>}
          </li>
        ))}
        {!accounts.length && <li className="border-t border-line px-5 py-3 text-muted">Nenhuma conta cadastrada.</li>}
      </ul>
    </Card>
  )
}

export function Registrations({ registrations, agreements, canReveal }: { registrations: Registration[]; agreements: { id: string; name: string }[]; canReveal: boolean }) {
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
              <Field name="Senha" value={r.has_portal_password ? (canReveal ? <RevealPassword registrationId={r.id} /> : '••••••••') : null} />
            </dl>
          </li>
        ))}
        {!registrations.length && <li className="border-t border-line px-5 py-3 text-muted">Nenhuma matrícula cadastrada.</li>}
      </ul>
    </Card>
  )
}
