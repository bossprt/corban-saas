'use client'

import { useState } from 'react'
import { Pencil } from 'lucide-react'
import { DISTRIBUTIONS, DISTRIBUTION_LABEL, type Distribution } from '@/lib/crm'

export type CampaignValues = {
  id?: string; name: string; description: string | null; distribution: Distribution; starts_on: string | null; ends_on: string | null
  status: 'active' | 'closed'; members: string[]
}
const label = 'text-[13px] font-medium text-ink-soft'

// The campaign form. On the campaign page it opens locked; "Editar campanha" unlocks it in place.
export function CampaignFields({ values, people, lockedAtStart }: { values: CampaignValues; people: { id: string; name: string }[]; lockedAtStart: boolean }) {
  const [editing, setEditing] = useState(!lockedAtStart)
  const [distribution, setDistribution] = useState<Distribution>(values.distribution)
  return (
    <div className="grid gap-4">
      {lockedAtStart && (
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="text-xs text-muted">{editing ? 'Editando: altere e clique em Salvar campanha.' : 'Para alterar, clique em Editar campanha.'}</p>
          {!editing && <button type="button" onClick={() => setEditing(true)} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm font-medium text-ink hover:bg-surface-muted"><Pencil size={15} aria-hidden />Editar campanha</button>}
        </div>
      )}
      <fieldset disabled={!editing} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {values.id && <input type="hidden" name="campaign_id" value={values.id} />}
        <label className={`${label} sm:col-span-2`}>Nome da campanha<input required name="name" minLength={2} maxLength={120} defaultValue={values.name} placeholder="Ex.: Refin INSS setembro" className="field mt-1.5" /></label>
        <label className={label}>Início<input type="date" name="starts_on" defaultValue={values.starts_on ?? ''} className="field mt-1.5" /></label>
        <label className={label}>Fim<input type="date" name="ends_on" defaultValue={values.ends_on ?? ''} className="field mt-1.5" /></label>
        <label className={`${label} sm:col-span-2 lg:col-span-4`}>Descrição (opcional)<input name="description" maxLength={500} defaultValue={values.description ?? ''} placeholder="Produto, público, argumento de venda..." className="field mt-1.5" /></label>
        <fieldset className="sm:col-span-2">
          <legend className={`${label} mb-1.5`}>Como os leads chegam aos vendedores</legend>
          <div className="grid gap-1.5">
            {DISTRIBUTIONS.map(d => (
              <label key={d} className="flex items-center gap-2 text-sm text-ink">
                <input type="radio" name="distribution" value={d} checked={distribution === d} onChange={() => setDistribution(d)} className="accent-[var(--brand)]" />{DISTRIBUTION_LABEL[d]}
              </label>
            ))}
          </div>
        </fieldset>
        <fieldset className="sm:col-span-2">
          <legend className={`${label} mb-1.5`}>Vendedores da campanha {distribution === 'queue' && <span className="font-normal text-muted">(nenhum marcado: todos podem pegar)</span>}</legend>
          <div className="grid max-h-48 gap-1.5 overflow-auto rounded-[10px] border border-line p-2.5">
            {people.map(p => (
              <label key={p.id} className="flex items-center gap-2 text-sm text-ink">
                <input type="checkbox" name="members" value={p.id} defaultChecked={values.members.includes(p.id)} className="accent-[var(--brand)]" />{p.name}
              </label>
            ))}
            {people.length === 0 && <span className="text-sm text-muted">Nenhum vendedor ativo.</span>}
          </div>
        </fieldset>
        {values.id && (
          <label className={label}>Situação
            <select name="status" defaultValue={values.status} className="field mt-1.5">
              <option value="active">Ativa</option>
              <option value="closed">Encerrada</option>
            </select>
          </label>
        )}
        <div className="flex items-end sm:col-span-2 lg:col-span-3">
          <button className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">{values.id ? 'Salvar campanha' : 'Criar campanha'}</button>
        </div>
      </fieldset>
    </div>
  )
}
