'use client'

import { useId, useMemo, useState } from 'react'
import type { ProposalCatalog } from '@/lib/proposals/catalog'

// Banco -> Tipo de contrato -> Tabela, each list narrowed by the previous choice (owner request 29/09/2026, ADR-0049).
// Posts the table version and the contract type under the given field names.
export function BankTypeTable({ catalog, versionName = 'table_version_id', typeName = 'contract_type_id', initialVersion, initialType, disabled, labelClass = 'text-[13px] font-medium text-ink-soft', onTypeChange }: {
  catalog: ProposalCatalog; versionName?: string; typeName?: string; initialVersion?: string | null; initialType?: string | null; disabled?: boolean; labelClass?: string
  // Tells the parent which contract type is chosen (e.g. to show the origin fields of a refinancing or a portability).
  onTypeChange?: (typeId: string) => void
}) {
  const id = useId()
  const start = catalog.tables.find(t => t.versionId === initialVersion)
  const [origin, setOrigin] = useState(start?.origin ?? '')
  const [type, setType] = useState(initialType ?? '')
  const [version, setVersion] = useState(start?.versionId ?? '')

  const typesHere = useMemo(() => {
    const ids = new Set(catalog.tables.filter(t => t.origin === origin).flatMap(t => t.types))
    return catalog.types.filter(t => ids.has(t.id))
  }, [catalog, origin])
  const tablesHere = useMemo(() => catalog.tables.filter(t => t.origin === origin && (!type || t.types.includes(type))), [catalog, origin, type])

  const pickOrigin = (o: string) => {
    setOrigin(o)
    const ids = new Set(catalog.tables.filter(t => t.origin === o).flatMap(t => t.types))
    const keepType = ids.has(type) ? type : ids.size === 1 ? [...ids][0] : ''
    setType(keepType)
    onTypeChange?.(keepType)
    if (!catalog.tables.some(t => t.versionId === version && t.origin === o && (!keepType || t.types.includes(keepType)))) setVersion('')
  }
  const pickType = (t: string) => {
    setType(t)
    onTypeChange?.(t)
    if (!catalog.tables.some(x => x.versionId === version && x.origin === origin && x.types.includes(t))) setVersion('')
  }

  return (
    <>
      <div className={labelClass}><label htmlFor={`${id}-bank`}>Banco</label>
        <select id={`${id}-bank`} required value={origin} onChange={e => pickOrigin(e.target.value)} disabled={disabled} className="field mt-1.5">
          <option value="" disabled>Escolha o banco</option>
          {catalog.origins.map(o => <option key={o.key} value={o.key}>{o.label}</option>)}
        </select>
      </div>
      <div className={labelClass}><label htmlFor={`${id}-type`}>Tipo de contrato</label>
        <select id={`${id}-type`} required name={typeName} value={type} onChange={e => pickType(e.target.value)} disabled={disabled || !origin} className="field mt-1.5">
          <option value="" disabled>{origin ? 'Escolha o tipo' : 'Escolha o banco primeiro'}</option>
          {typesHere.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
      </div>
      <div className={labelClass}><label htmlFor={`${id}-table`}>Tabela</label>
        <select id={`${id}-table`} required name={versionName} value={version} onChange={e => setVersion(e.target.value)} disabled={disabled || !origin || !type} className="field mt-1.5">
          <option value="" disabled>{!origin ? 'Escolha o banco primeiro' : !type ? 'Escolha o tipo primeiro' : tablesHere.length ? `Escolha entre ${tablesHere.length} tabela(s)` : 'Nenhuma tabela deste tipo'}</option>
          {tablesHere.map(t => <option key={t.versionId} value={t.versionId}>{t.label}</option>)}
        </select>
      </div>
    </>
  )
}
