// Client profile (ADR-0033): labels and the "incomplete profile" rule. Pure, no I/O.
export const UFS = ['AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA', 'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'] as const
export const GENDER_LABEL: Record<string, string> = { F: 'Feminino', M: 'Masculino', N: 'Não informar' }
export const MARITAL_LABEL: Record<string, string> = { single: 'Solteiro(a)', married: 'Casado(a)', stable_union: 'União estável', divorced: 'Divorciado(a)', separated: 'Separado(a)', widowed: 'Viúvo(a)' }
export const ACCOUNT_TYPE_LABEL: Record<string, string> = { checking: 'Conta corrente', savings: 'Poupança', salary: 'Conta salário', payment: 'Conta de pagamento' }

export type ProfileFields = {
  birth_date: string | null; father_name: string | null; mother_name: string | null; rg_number: string | null; rg_issuer: string | null
  rg_state: string | null; rg_issued_on: string | null; gender: string | null; marital_status: string | null; birthplace_city: string | null
  birthplace_state: string | null; whatsapp: string | null
}

const REQUIRED: [keyof ProfileFields, string][] = [
  ['birth_date', 'data de nascimento'], ['mother_name', 'nome da mãe'], ['father_name', 'nome do pai'], ['rg_number', 'RG'],
  ['rg_issuer', 'órgão expedidor'], ['rg_state', 'UF do RG'], ['rg_issued_on', 'data de emissão do RG'], ['gender', 'sexo'],
  ['marital_status', 'estado civil'], ['birthplace_city', 'naturalidade'], ['whatsapp', 'WhatsApp'],
]

// What is missing for a complete profile (nothing blocks the registration; the screen shows the list).
export function missingProfileFields(p: Partial<ProfileFields>, extras: { hasBankAccount: boolean; hasRegistration: boolean }): string[] {
  const missing = REQUIRED.filter(([k]) => !p[k]).map(([, label]) => label)
  if (!extras.hasBankAccount) missing.push('dados bancários')
  if (!extras.hasRegistration) missing.push('matrícula')
  return missing
}

// Age in whole years on a given date (ISO yyyy-mm-dd strings; no time zone drift).
export function ageOn(birth: string, today: string): number {
  const [by, bm, bd] = birth.split('-').map(Number)
  const [ty, tm, td] = today.split('-').map(Number)
  return ty - by - (tm < bm || (tm === bm && td < bd) ? 1 : 0)
}

// yyyy-mm-dd → dd/mm/yyyy without Date parsing (no time zone shift).
export const dateBr = (iso: string | null | undefined) => (iso && /^\d{4}-\d{2}-\d{2}/.test(iso) ? `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}` : '—')
