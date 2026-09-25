import Link from 'next/link'
import { ArrowLeft } from 'lucide-react'
import { SubmitButton } from '@/components/SubmitButton'
import { Badge, Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf } from '@/lib/cpf'
import { brlText } from '@/lib/receipts/format'
import { decidePortalProposal } from './actions'

type Row = { proposal_id: string; created_at: string; seller_name: string; client_name: string; client_cpf: string; bank: string; table_name: string;
  requested_amount: string | null; released_amount: string | null; term: number | null; ade: string | null; client_preexisted: boolean; client_owner_name: string | null; documents: number }

// Proposals sent through the broker portal, waiting for someone who may edit the pipeline (never the sender).
export default async function ValidationQueuePage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'esteira.edit')) {
    return <section><PageHeader title="Aguardando validação" /><Card className="p-5 text-sm text-ink-soft">Seu papel não valida propostas do portal.</Card></section>
  }
  const { data } = await supabase.rpc('broker_submission_queue', { p_org: organization.id })
  const rows = (data ?? []) as Row[]
  const ids = rows.map(r => r.proposal_id)
  const { data: docs } = ids.length ? await supabase.from('proposal_submission_documents').select('proposal_id,label,storage_path').in('proposal_id', ids) : { data: [] }
  const { data: signed } = docs?.length ? await supabase.storage.from('corban-documents').createSignedUrls(docs.map(d => d.storage_path), 600) : { data: [] }
  const link = new Map((signed ?? []).map(x => [x.path, x.signedUrl]))

  return (
    <section>
      <Link href="/app/propostas" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Esteira</Link>
      <PageHeader title="Aguardando validação" description="Propostas enviadas pelo portal do corretor. Ao validar, a proposta entra na esteira; ao recusar, o corretor vê o motivo." />
      <div className="grid gap-3">
        {rows.map(r => (
          <Card key={r.proposal_id} className="p-5">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div className="font-semibold text-ink">{r.client_name} <span className="font-mono text-sm font-normal text-muted">{formatCpf(r.client_cpf)}</span></div>
                <div className="mt-0.5 text-sm text-ink-soft">{r.bank} · {r.table_name} · <span className="num">{brlText(r.released_amount ?? r.requested_amount)}</span>{r.term ? ` em ${r.term}x` : ''}{r.ade ? <> · ADE <span className="font-mono">{r.ade}</span></> : ''}</div>
                <div className="mt-0.5 text-xs text-muted">Enviada por {r.seller_name} em {new Date(r.created_at).toLocaleString('pt-BR')}</div>
                {r.client_preexisted && <div className="mt-2"><Badge tone="diverged">Cliente já existe · carteira de {r.client_owner_name}</Badge></div>}
                <div className="mt-2 flex flex-wrap gap-2 text-xs">
                  {(docs ?? []).filter(d => d.proposal_id === r.proposal_id).map(d => link.get(d.storage_path)
                    ? <a key={d.storage_path} href={link.get(d.storage_path)!} target="_blank" rel="noreferrer" className="rounded-md border border-line px-2 py-1 text-brand hover:bg-surface-muted">{d.label}</a>
                    : <span key={d.storage_path} className="rounded-md border border-line px-2 py-1 text-muted">{d.label}</span>)}
                  {!r.documents && <span className="text-muted">Sem documentos anexados.</span>}
                </div>
              </div>
              <div className="flex flex-col gap-2">
                <form action={decidePortalProposal}><input type="hidden" name="proposal_id" value={r.proposal_id} /><input type="hidden" name="decision" value="approve" />
                  <SubmitButton className="h-9 w-full rounded-md bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Validando...">Validar</SubmitButton></form>
                <form action={decidePortalProposal} className="flex gap-1"><input type="hidden" name="proposal_id" value={r.proposal_id} /><input type="hidden" name="decision" value="reject" />
                  <input name="reason" required minLength={3} maxLength={300} placeholder="Motivo da recusa" aria-label="Motivo da recusa" className="field h-9 w-48 text-sm" />
                  <SubmitButton className="h-9 rounded-md border border-line px-3 text-sm text-ink-soft hover:bg-surface-muted" pendingText="...">Recusar</SubmitButton></form>
              </div>
            </div>
          </Card>
        ))}
        {!rows.length && <Card className="p-8 text-center text-sm text-muted">Nenhuma proposta do portal aguardando validação.</Card>}
      </div>
    </section>
  )
}
