'use client'

import { useState } from 'react'
import { BankTypeTable } from '@/components/BankTypeTable'
import type { ProposalCatalog } from '@/lib/proposals/catalog'

export type OriginValues = { outstanding_balance: string; origin_bank_name: string; origin_contract_number: string }

// Banco -> Tipo de contrato -> Tabela, plus the origin of a refinancing, portability or debt purchase (owner request
// 01/10/2026): saldo devedor, banco de origem and nº do contrato de origem. Record only, optional, hidden for "Novo".
// The fields stay in the form (hidden) so editing a contract never clears them by accident.
export function ContractChoice({ catalog, initialVersion, initialType, origin, labelClass, gridClass = 'grid gap-4 sm:grid-cols-3', disabled }: {
  catalog: ProposalCatalog; initialVersion?: string | null; initialType?: string | null; origin?: Partial<OriginValues>; labelClass?: string; gridClass?: string; disabled?: boolean
}) {
  const [type, setType] = useState(initialType ?? '')
  const key = catalog.types.find(t => t.id === type)?.key
  const showOrigin = !!type && key !== 'novo'
  const lbl = labelClass ?? 'text-[13px] font-medium text-ink-soft'
  return (
    <>
      <div className={gridClass}>
        <BankTypeTable catalog={catalog} initialVersion={initialVersion} initialType={initialType} onTypeChange={setType} disabled={disabled} labelClass={lbl} />
      </div>
      <div className={showOrigin ? gridClass : 'hidden'}>
        <label className={lbl}>Saldo devedor (R$)<input name="outstanding_balance" disabled={disabled || !showOrigin} inputMode="decimal" placeholder="8.500,00" defaultValue={origin?.outstanding_balance ?? ''} className="field mt-1.5" /></label>
        <label className={lbl}>Banco de origem<input name="origin_bank_name" disabled={disabled || !showOrigin} maxLength={120} placeholder="Ex.: Banco do Brasil" defaultValue={origin?.origin_bank_name ?? ''} className="field mt-1.5" /></label>
        <label className={lbl}>Nº do contrato de origem<input name="origin_contract_number" disabled={disabled || !showOrigin} maxLength={60} defaultValue={origin?.origin_contract_number ?? ''} className="field mt-1.5" /></label>
      </div>
    </>
  )
}
