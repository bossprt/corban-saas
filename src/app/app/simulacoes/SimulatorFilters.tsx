'use client'
import { useState } from 'react'

// terms: the months each operation (contract type id) of the table has.
export type TableOption = { key: string; label: string; agreementId: string; bankId: string; bankName: string; typeIds: string[]; terms: Record<string, number[]> }
const label = 'text-[13px] font-medium text-ink-soft'

// Convênio, banco, operação, tabela and prazo for the GET form of the simulator. The bank, table and term lists follow
// the choices above them; "Todos os bancos" / "Todas as tabelas" compare every one (owner, 08/10/2026: pick one table to
// go straight to the point; 30/10/2026: pick the bank, and the term from the terms the tables really have).
// A bank table sold by several promoters is ONE option (same bank code, same factor).
export function SimulatorFilters({ agreements, types, tables, initial }: {
  agreements: { id: string; name: string }[]; types: { id: string; name: string }[]; tables: TableOption[]
  initial: { agreement: string; bank: string; type: string; table: string; term: string }
}) {
  const [agreement, setAgreement] = useState(initial.agreement)
  const [bank, setBank] = useState(initial.bank)
  const [type, setType] = useState(initial.type)
  const [table, setTable] = useState(initial.table)
  const [term, setTerm] = useState(initial.term)
  const ofAgreement = tables.filter(t => t.agreementId === agreement && (!type || t.typeIds.includes(type)))
  const banks = [...new Map(ofAgreement.map(t => [t.bankId, t.bankName || 'Banco sem nome'])).entries()].sort((a, b) => a[1].localeCompare(b[1], 'pt-BR'))
  const bankValue = banks.some(([id]) => id === bank) ? bank : ''
  const options = ofAgreement.filter(t => !bankValue || t.bankId === bankValue)
  const value = options.some(o => o.key === table) ? table : ''
  const chosen = value ? options.filter(o => o.key === value) : options
  const terms = [...new Set(chosen.flatMap(o => type ? o.terms[type] ?? [] : Object.values(o.terms).flat()))].sort((a, b) => a - b)
  const termValue = terms.includes(Number(term)) ? term : ''
  const bankLabel = banks.find(([id]) => id === bankValue)?.[1]
  return <>
    <label className={`${label} lg:col-span-2`}>Convênio
      <select name="convenio" required value={agreement} onChange={e => { setAgreement(e.target.value); setBank(''); setTable('') }} className="field mt-1.5">
        <option value="" disabled>Escolha</option>
        {agreements.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
      </select>
    </label>
    <label className={`${label} lg:col-span-2`}>Banco
      <select name="banco" value={bankValue} onChange={e => { setBank(e.target.value); setTable('') }} disabled={!agreement} className="field mt-1.5">
        <option value="">{agreement ? `Todos os bancos (${banks.length})` : 'Escolha o convênio'}</option>
        {banks.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </select>
    </label>
    <label className={`${label} lg:col-span-2`}>Operação
      <select name="tipo" required value={type} onChange={e => { setType(e.target.value); setTable('') }} className="field mt-1.5">
        <option value="" disabled>Escolha</option>
        {types.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
      </select>
    </label>
    <label className={`${label} sm:col-span-2 lg:col-span-4`}>Tabela
      <select name="tabela" value={value} onChange={e => setTable(e.target.value)} disabled={!agreement} className="field mt-1.5">
        <option value="">{agreement ? `Todas as tabelas${bankLabel ? ` do ${bankLabel}` : ''} (${options.length})` : 'Escolha o convênio'}</option>
        {options.map(o => <option key={o.key} value={o.key}>{o.label}</option>)}
      </select>
    </label>
    <label className={`${label} lg:col-span-2`}>Prazo (meses)
      <select name="prazo" required value={termValue} onChange={e => setTerm(e.target.value)} disabled={!terms.length} className="field mt-1.5">
        <option value="" disabled>{!agreement ? 'Escolha o convênio' : terms.length ? 'Escolha' : 'Sem prazo nas tabelas'}</option>
        {terms.map(n => <option key={n} value={n}>{n}x</option>)}
      </select>
    </label>
  </>
}
