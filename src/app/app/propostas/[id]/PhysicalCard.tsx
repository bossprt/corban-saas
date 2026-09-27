import { Check } from 'lucide-react'
import { Badge, Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { memberEmails } from '@/lib/team.server'
import { setContractPhysical } from './contract-actions'

type Physical = { received_at: string | null; received_by: string | null; sent_at: string | null; sent_by: string | null; bank_at: string | null; bank_by: string | null }
const STEPS = [
  { key: 'received', label: 'Recebido pela empresa', at: 'received_at', by: 'received_by' },
  { key: 'sent', label: 'Enviado ao banco', at: 'sent_at', by: 'sent_by' },
  { key: 'bank', label: 'Recepcionado pelo banco', at: 'bank_at', by: 'bank_by' },
] as const
// Now in Brazil (UTC-3) for the datetime-local default.
const nowLocal = () => new Date(Date.now() - 3 * 3_600_000).toISOString().slice(0, 16)

// The physical file of a physical contract (part C3): three milestones in order, each with date, time and who. The
// seller's credit waits for "Recebido pela empresa".
export async function PhysicalCard({ proposalId, p, canEdit }: { proposalId: string; p: Physical; canEdit: boolean }) {
  const who = await memberEmails([p.received_by, p.sent_by, p.bank_by].filter((x): x is string => !!x))
  const next = STEPS.find(s => !p[s.at])
  return (
    <Card id="fisico" className="mt-4">
      <CardHeader title={<span className="flex items-center gap-2">Físico <Badge tone={p.received_at ? 'received' : 'pending'}>{p.bank_at ? 'Recepcionado pelo banco' : p.sent_at ? 'Enviado ao banco' : p.received_at ? 'Recebido pela empresa' : 'Aguardando o físico'}</Badge></span>} />
      <ol className="grid gap-2 p-5 pt-3 sm:grid-cols-3">
        {STEPS.map(s => {
          const at = p[s.at], by = p[s.by]
          return (
            <li key={s.key} className={`rounded-[12px] border px-4 py-3 text-sm ${at ? 'border-[#86EFAC] bg-[#F0FDF4]' : 'border-line'}`}>
              <div className="flex items-center gap-1.5 font-medium text-ink">{at && <Check size={15} aria-hidden className="text-[#15803D]" />}{s.label}</div>
              {at ? <p className="mt-1 text-xs text-muted">{new Date(at).toLocaleString('pt-BR')}{by ? ` · ${who.get(by) ?? 'usuário'}` : ''}</p>
                : canEdit && next?.key === s.key ? (
                  <form action={setContractPhysical} className="mt-2 flex flex-wrap items-end gap-2">
                    <input type="hidden" name="proposal_id" value={proposalId} /><input type="hidden" name="step" value={s.key} />
                    <input type="datetime-local" name="at" required defaultValue={nowLocal()} aria-label={`${s.label} em`} className="field h-9 w-auto" />
                    <SubmitButton className="h-9 rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="...">Registrar</SubmitButton>
                  </form>
                ) : <p className="mt-1 text-xs text-muted">Pendente</p>}
            </li>
          )
        })}
      </ol>
    </Card>
  )
}
