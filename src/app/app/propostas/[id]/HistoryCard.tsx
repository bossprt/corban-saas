import { Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { brlText } from '@/lib/receipts/format'
import { decimalBr } from '@/lib/commission/tableValues'
import { memberEmails } from '@/lib/team.server'
import { addContractNote } from './contract-actions'
import { CALC_FAILURE } from './CommissionCard'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type ContractEvent = { id: string; kind: string; detail: Record<string, unknown>; reason: string | null; actor_user_id: string | null; created_at: string }
type StageEvent = { id: string; from_state: string | null; to_state: string | null; actor_user_id: string | null; metadata: Record<string, unknown> | null; occurred_at: string }

const STATE: Record<string, string> = {
  digitization_queue: 'Aguardando digitação', digitizing: 'Em digitação', submitted: 'Em análise', pending_external: 'Pendência',
  approved: 'Aprovado', paid: 'Pago ao cliente', rejected: 'Recusado', cancelled: 'Cancelado',
}
const FIELD: Record<string, string> = { table_version_id: 'Tabela', seller_id: 'Vendedor', requested_amount: 'Valor bruto', released_amount: 'Valor líquido', installment_amount: 'Parcela', term: 'Prazo' }
const COMPONENT: Record<string, string> = { upfront: 'à vista', deferred: 'diferido', bonus_1: 'bônus 1', bonus_2: 'bônus 2', bonus_3: 'bônus 3', plastic: 'plástico', insurance_fixed: 'seguro' }
const money = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : brlText(String(v)))
const fieldValue = (k: string, side: unknown, label?: unknown) =>
  k.endsWith('_amount') ? money(side) : k === 'term' ? (side ? `${String(side)}x` : '—') : String(label ?? '—')

function describe(e: ContractEvent): string {
  const d = e.detail ?? {}
  if (e.kind === 'note') return e.reason ?? ''
  if (e.kind === 'edit') {
    return Object.entries(d).map(([k, v]) => {
      const c = (v ?? {}) as Record<string, unknown>
      return `${FIELD[k] ?? k}: ${fieldValue(k, c.from, c.from_label)} → ${fieldValue(k, c.to, c.to_label)}`
    }).join(' · ')
  }
  if (e.kind === 'payout_override') {
    const how = d.value_kind === 'fixed_brl' ? 'valor fixo' : `${decimalBr(String(d.value ?? ''))}% da base`
    return `Repasse do vendedor (${COMPONENT[String(d.component)] ?? d.component}): ${money(d.previous)} → ${money(d.payable)} (${how}; pela regra ${money(d.rule_amount)})`
  }
  if (e.kind === 'payout_override_cleared') return `Repasse do vendedor (${COMPONENT[String(d.component)] ?? d.component}) voltou para a regra: ${money(d.payable)}`
  if (e.kind === 'recalculated') return 'Comissão recalculada'
  if (e.kind === 'calc_failed') return `Comissão não calculada: ${CALC_FAILURE[String(d.code)] ?? String(d.code ?? '')}`
  return e.kind
}

// One history of the contract (part C2): stage moves, edits (before -> after), payout changes (finance only, by RLS)
// and notes, newest first. Notes are written here and never deleted.
export async function HistoryCard({ supabase, proposalId }: { supabase: Supa; proposalId: string }) {
  const { data: oc } = await supabase.from('operational_cases').select('id').eq('proposal_id', proposalId).maybeSingle()
  const [{ data: events }, { data: stages }] = await Promise.all([
    supabase.from('contract_events').select('id,kind,detail,reason,actor_user_id,created_at').eq('proposal_id', proposalId).order('created_at', { ascending: false }).limit(200),
    oc ? supabase.from('operational_events').select('id,from_state,to_state,actor_user_id,metadata,occurred_at').eq('operational_case_id', oc.id).order('occurred_at', { ascending: false }).limit(200) : Promise.resolve({ data: [] }),
  ])
  const items = [
    ...((events ?? []) as ContractEvent[]).map(e => ({ id: `c-${e.id}`, at: e.created_at, actor: e.actor_user_id, title: e.kind === 'note' ? 'Observação' : e.kind === 'edit' ? 'Contrato alterado' : e.kind.startsWith('payout') ? 'Repasse alterado' : 'Comissão', text: describe(e), reason: e.kind === 'note' ? null : e.reason })),
    ...((stages ?? []) as StageEvent[]).map(s => ({ id: `s-${s.id}`, at: s.occurred_at, actor: s.actor_user_id, title: 'Esteira', text: `${s.from_state ? `${STATE[s.from_state] ?? s.from_state} → ` : ''}${STATE[s.to_state ?? ''] ?? s.to_state ?? ''}`, reason: typeof s.metadata?.note === 'string' ? s.metadata.note : null })),
  ].sort((a, b) => b.at.localeCompare(a.at))
  const who = await memberEmails(items.map(i => i.actor).filter((x): x is string => !!x))

  return (
    <Card id="historico" className="mt-4">
      <CardHeader title="Histórico e observações" />
      <form action={addContractNote} className="flex flex-wrap items-end gap-2 px-5 pt-3">
        <input type="hidden" name="proposal_id" value={proposalId} />
        <label className="flex-1 text-[13px] font-medium text-ink-soft">Nova observação<textarea name="note" required maxLength={2000} rows={2} className="field mt-1.5 min-h-[44px]" /></label>
        <SubmitButton className="h-10 rounded-[10px] border border-line-strong bg-surface px-4 text-sm text-ink hover:bg-surface-muted" pendingText="Salvando...">Registrar observação</SubmitButton>
      </form>
      <ol className="mt-4">
        {items.map(i => (
          <li key={i.id} className="border-t border-line px-5 py-3 text-sm">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="font-medium text-ink">{i.title}</span>
              <span className="text-xs text-muted">{new Date(i.at).toLocaleString('pt-BR')}{i.actor ? ` · ${who.get(i.actor) ?? 'usuário'}` : ''}</span>
            </div>
            <p className="mt-0.5 whitespace-pre-line text-ink-soft">{i.text}</p>
            {i.reason && <p className="mt-0.5 text-xs text-muted">Motivo: {i.reason}</p>}
          </li>
        ))}
        {!items.length && <li className="border-t border-line px-5 py-4 text-sm text-muted">Nada registrado ainda.</li>}
      </ol>
    </Card>
  )
}
