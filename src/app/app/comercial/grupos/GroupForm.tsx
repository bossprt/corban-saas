'use client'

import { useState } from 'react'
import { Pencil, X } from 'lucide-react'
import { SubmitButton } from '@/components/SubmitButton'
import { BASIS_LABEL, pctText, referenceValue, type HierarchyBasis, type ReferenceKind } from '@/lib/commission/groupRule'

const lbl = 'text-[13px] font-medium text-ink-soft'
const legend = 'mb-2 text-sm font-semibold text-ink'

export type GroupRuleValues = {
  own_production: boolean
  supervisor_basis: HierarchyBasis; supervisor_pct: string
  manager_basis: HierarchyBasis; manager_pct: string
  items: Record<string, { reference_kind: ReferenceKind; reference_group_id: string | null; distributed_pct: string }>
}

// The seller group screen (owner decision 25/09/2026): name, own production, and for each commission type the table
// column the group reads and how many % of it is paid out; then supervisor and sales manager. An existing group opens
// locked; "Editar grupo" unlocks it in place (the record page is the form).
export function GroupForm({ action, group, rule, components, otherGroups, canEdit }: {
  action: (f: FormData) => Promise<void>
  group?: { id: string; name: string }
  rule?: GroupRuleValues
  components: { tech_key: string; name: string }[]
  otherGroups: { id: string; name: string }[]
  canEdit: boolean
}) {
  const [editing, setEditing] = useState(!group)
  const [round, setRound] = useState(0)
  const [own, setOwn] = useState(rule?.own_production ?? false)
  const locked = !editing

  const hierarchy = (who: 'supervisor' | 'manager', title: string) => (
    <fieldset className="grid content-start gap-2">
      <legend className={legend}>{title}</legend>
      {(Object.keys(BASIS_LABEL) as HierarchyBasis[]).map(b => (
        <label key={b} className="flex items-center gap-2 text-sm text-ink">
          <input type="radio" name={`${who}_basis`} value={b} defaultChecked={(rule?.[`${who}_basis`] ?? 'spread') === b} className="accent-[var(--brand)]" />
          {BASIS_LABEL[b]}
        </label>
      ))}
      <label className={`${lbl} mt-1 max-w-[220px]`}>Percentual (%)
        <input name={`${who}_pct`} defaultValue={pctText(rule?.[`${who}_pct`] ?? '0')} inputMode="decimal" className="field mt-1.5" />
      </label>
    </fieldset>
  )

  return (
    <form action={action} className="grid gap-5">
      {group && <input type="hidden" name="group_id" value={group.id} />}
      {group && canEdit && (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-muted">{locked ? 'Para alterar, clique em Editar grupo. Cada alteração vira uma nova versão da regra; as anteriores ficam guardadas.' : 'Editando: altere o que precisar e clique em Salvar grupo.'}</p>
          {locked
            ? <button type="button" onClick={() => setEditing(true)} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm font-medium text-ink hover:bg-surface-muted"><Pencil size={15} aria-hidden />Editar grupo</button>
            : <button type="button" onClick={() => { setEditing(false); setOwn(rule?.own_production ?? false); setRound(r => r + 1) }} className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 text-sm text-ink-soft hover:bg-surface-muted"><X size={15} aria-hidden />Cancelar</button>}
        </div>
      )}
      <fieldset key={round} disabled={locked} className="grid gap-6">
        <div className="grid gap-3 md:grid-cols-2">
          <label className={lbl}>Nome do grupo<input required name="name" maxLength={80} defaultValue={group?.name ?? ''} placeholder="Ex.: Corretor, Parceiro, Balcão" className="field mt-1.5" /></label>
          <label className="flex items-end gap-2 pb-2.5 text-sm text-ink">
            <input type="checkbox" name="own_production" checked={own} onChange={e => setOwn(e.target.checked)} className="accent-[var(--brand)]" />
            Produção própria: a empresa fica com 100% (sem coluna de repasse)
          </label>
        </div>

        {own ? (
          <p className="rounded-[12px] border border-line bg-surface-muted/50 p-4 text-sm text-ink-soft">
            Vendas deste grupo não geram repasse: a comissão inteira fica com a empresa, e as tabelas não terão coluna para ele. Supervisor e gerente, se tiverem percentual, são calculados normalmente.
          </p>
        ) : (
          <fieldset>
            <legend className={legend}>Repasse por tipo de comissão</legend>
            <p className="mb-3 text-xs text-muted">Para cada comissão que a empresa recebe: de qual coluna da tabela o valor é lido e quantos % dele o vendedor recebe.</p>
            <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
              {components.map(c => {
                const it = rule?.items[c.tech_key]
                return (
                  <div key={c.tech_key} className="grid gap-2 rounded-[12px] border border-line p-3" data-row="component">
                    <input type="hidden" name="component" value={c.tech_key} />
                    <span className="text-sm font-semibold text-ink">{c.name}</span>
                    <label className={lbl}>Coluna de referência
                      <select name={`ref_${c.tech_key}`} defaultValue={it ? referenceValue(it.reference_kind, it.reference_group_id) : 'own'} className="field mt-1.5">
                        <option value="own">Coluna do próprio grupo</option>
                        <option value="company">Coluna Empresa (o que a empresa recebe)</option>
                        {otherGroups.map(g => <option key={g.id} value={`group:${g.id}`}>Coluna {g.name}</option>)}
                      </select>
                    </label>
                    <label className={lbl}>Quantos % serão distribuídos
                      <input name={`pct_${c.tech_key}`} defaultValue={it ? pctText(it.distributed_pct) : '100,00'} inputMode="decimal" className="field mt-1.5" />
                    </label>
                  </div>
                )
              })}
            </div>
          </fieldset>
        )}

        <div className="grid gap-6 md:grid-cols-2">
          {hierarchy('supervisor', 'Supervisor')}
          {hierarchy('manager', 'Gerente comercial')}
        </div>
      </fieldset>
      {editing && (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-muted">Percentuais de 0 a 100, com vírgula. Cada empresa define as próprias regras.</p>
          <SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">{group ? 'Salvar grupo' : 'Cadastrar grupo'}</SubmitButton>
        </div>
      )}
    </form>
  )
}
