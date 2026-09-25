import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { SubmitButton } from '@/components/SubmitButton'
import { Badge, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { maskCpf } from '@/lib/cpf'
import { proposalStatusLabel } from '@/lib/operational'
import { isPortalUser, SUBMISSION_LABEL } from '@/lib/portal'
import { brlText } from '@/lib/receipts/format'
import { isUuid } from '@/lib/team'
import { CommissionCard } from '../../../propostas/[id]/CommissionCard'
import { uploadPortalDocument } from '../../actions'

const TONE: Record<string, Tone> = { pending: 'pending', validated: 'received', rejected: 'reversed' }
const label = 'text-[13px] font-medium text-ink-soft'

// One proposal the broker sent: situation, refusal reason, documents and (once validated) their own commission share.
export default async function PortalProposalPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, access, modules } = await requireAppContext()
  if (!isPortalUser(access?.roleKey, modules)) redirect(`/app/propostas/${id}`)
  const [{ data: p }, { data: s }, { data: docs }] = await Promise.all([
    supabase.from('proposals_v2').select('id,status,customer_snapshot,commercial_snapshot,requested_amount,released_amount,installment_amount,term,external_proposal_id,created_at').eq('id', id).maybeSingle(),
    supabase.from('proposal_submissions').select('status,decision_reason,decided_at,created_at').eq('proposal_id', id).maybeSingle(),
    supabase.from('proposal_submission_documents').select('id,label,original_file_name,storage_path,created_at').eq('proposal_id', id).order('created_at'),
  ])
  if (!p || !s) notFound()
  const { data: signed } = docs?.length ? await supabase.storage.from('corban-documents').createSignedUrls(docs.map(d => d.storage_path), 300) : { data: [] }
  const link = new Map((signed ?? []).map(x => [x.path, x.signedUrl]))
  const client = (p.customer_snapshot ?? {}) as { full_name?: string; cpf?: string }
  const deal = (p.commercial_snapshot ?? {}) as { bank?: string; table?: string }
  const situation = s.status === 'validated' ? proposalStatusLabel(p.status).label : SUBMISSION_LABEL[s.status]

  return (
    <section>
      <Link href="/app/portal" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Minhas propostas</Link>
      <PageHeader title={client.full_name ?? 'Proposta'} description={<>CPF {maskCpf(client.cpf)} · enviada em {new Date(s.created_at).toLocaleString('pt-BR')}</>} />

      <Card className="mb-4 p-5">
        <div className="flex flex-wrap items-center gap-2"><Badge tone={TONE[s.status] ?? 'neutral'}>{situation}</Badge>
          {s.status === 'pending' && <span className="text-sm text-muted">A empresa vai conferir e validar. Você pode anexar os documentos abaixo.</span>}</div>
        {s.status === 'rejected' && <p className="mt-2 text-sm text-[#991B1B]">Recusada: {s.decision_reason}</p>}
        <dl className="mt-4 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <div><dt className="text-xs text-muted">Banco e tabela</dt><dd className="text-ink">{deal.bank} · {deal.table}</dd></div>
          <div><dt className="text-xs text-muted">Valor</dt><dd className="num text-ink">{brlText(p.released_amount ?? p.requested_amount)}</dd></div>
          <div><dt className="text-xs text-muted">Parcela e prazo</dt><dd className="num text-ink">{brlText(p.installment_amount)}{p.term ? ` em ${p.term}x` : ''}</dd></div>
          <div><dt className="text-xs text-muted">ADE</dt><dd className="font-mono text-ink">{p.external_proposal_id ?? '—'}</dd></div>
        </dl>
      </Card>

      <Card className="mb-4 overflow-hidden">
        <CardHeader title="Documentos" />
        <ul className="mt-3 text-sm">
          {(docs ?? []).map(d => (
            <li key={d.id} className="flex items-center justify-between gap-3 border-t border-line px-5 py-2.5">
              <span><span className="font-medium text-ink">{d.label}</span> <span className="text-xs text-muted">{d.original_file_name}</span></span>
              {link.get(d.storage_path) && <a href={link.get(d.storage_path)!} target="_blank" rel="noreferrer" className="text-xs text-brand hover:underline">Abrir</a>}
            </li>
          ))}
          {!docs?.length && <li className="border-t border-line px-5 py-4 text-muted">Nenhum documento anexado.</li>}
        </ul>
        {s.status === 'pending' && (
          <form action={uploadPortalDocument} className="grid gap-3 border-t border-line p-5 sm:grid-cols-[1fr_2fr_auto] sm:items-end">
            <input type="hidden" name="proposal_id" value={p.id} />
            <label className={label}>Documento<input name="label" required minLength={2} maxLength={60} placeholder="RG, contracheque..." className="field mt-1.5" /></label>
            <label className={label}>Arquivo (PDF, JPG, PNG ou WebP, até 4 MB)<input name="file" type="file" required accept="application/pdf,image/jpeg,image/png,image/webp" className="field mt-1.5" /></label>
            <SubmitButton className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-muted" pendingText="Enviando...">Anexar</SubmitButton>
          </form>
        )}
      </Card>

      {s.status === 'validated' && <CommissionCard supabase={supabase} access={access} proposalId={p.id} closed={['paid', 'rejected', 'cancelled'].includes(p.status)} />}
    </section>
  )
}
