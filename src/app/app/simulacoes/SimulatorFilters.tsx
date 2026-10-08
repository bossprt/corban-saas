'use client'
import { useState } from 'react'

export type TableOption = { key: string; label: string; agreementId: string; typeIds: string[] }
const label = 'text-[13px] font-medium text-ink-soft'

// Convênio, operação and tabela for the GET form of the simulator. The table list follows the chosen agreement and
// operation; "Todas as tabelas" compares every one (owner, 08/10/2026: pick one table to go straight to the point).
// A bank table sold by several promoters is ONE option (same bank code, same factor).
export function SimulatorFilters({ agreements, types, tables, initial }: {
  agreements: { id: string; name: string }[]; types: { id: string; name: string }[]; tables: TableOption[]
  initial: { agreement: string; type: string; table: string }
}) {
  const [agreement, setAgreement] = useState(initial.agreement)
  const [type, setType] = useState(initial.type)
  const [table, setTable] = useState(initial.table)
  const options = tables.filter(t => t.agreementId === agreement && (!type || t.typeIds.includes(type)))
  const value = options.some(o => o.key === table) ? table : ''
  return <>
    <label className={`${label} lg:col-span-2`}>Convênio
      <select name="convenio" required value={agreement} onChange={e => { setAgreement(e.target.value); setTable('') }} className="field mt-1.5">
        <option value="" disabled>Escolha</option>
        {agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
      </select>
    </label>
    <label className={label}>Operação
      <select name="tipo" required value={type} onChange={e => { setType(e.target.value); setTable('') }} className="field mt-1.5">
        <option value="" disabled>Escolha</option>
        {types.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
      </select>
    </label>
    <label className={`${label} sm:col-span-2 lg:col-span-3`}>Tabela
      <select name="tabela" value={value} onChange={e => setTable(e.target.value)} disabled={!agreement} className="field mt-1.5">
        <option value="">{agreement ? `Todas as tabelas (${options.length})` : 'Escolha o convênio'}</option>
        {options.map(o => <option key={o.key} value={o.key}>{o.label}</option>)}
      </select>
    </label>
  </>
}
