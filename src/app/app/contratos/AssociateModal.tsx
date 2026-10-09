import { Suspense } from 'react'
import Link from 'next/link'
import { X } from 'lucide-react'
import { Badge } from '@/components/ui'
import { FlashBanner } from '@/components/FlashBanner'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf } from '@/lib/cpf'
import { cancelLink, linkSeller } from './quick-actions'

const lbl = 'block text-[13px] font-medium text-ink-soft'
const STATUS: Record<string, [string, 'pending' | 'received' | 'neutral']> = { waiting: ['Aguardando o contrato', 'pending'], used: ['Usada', 'received'], cancelled: ['Cancelada', 'neutral'] }
type Link_ = { id: string; org_bank_id: string; ade: string | null; cpf: string | null; client_name: string | null; seller_id: string; status: string; proposal_id: string | null; matched_by: string | null; cancel_reason: string | null; created_at: string; used_at: string | null }

// "Associar proposta" (owner, 08/10/2026): who sold a proposal typed at a bank, before the contract reaches the Corban.
// The seller goes to the contract when it arrives (by ADE, else by CPF for a new contract) and wins over the
// spreadsheet's seller. The list keeps every association (waiting, used, cancelled with the reason).
export async function AssociateModal({ back }: { back: string }) {
  const { supabase } = await requireAppContext()
  const [{ data: banks }, { data: sellers }, { data: rows }] = await Promise.all([
    supabase.from('organization_banks').select('id,name').eq('is_active', true).order('name'),
    supabase.from('commercial_sellers').select('id,name,code').eq('is_active', true).order('name'),
    supabase.from('proposal_seller_links').select('id,org_bank_id,ade,cpf,client_name,seller_id,status,proposal_id,matched_by,cancel_reason,created_at,used_at')
      .order('created_at', { ascending: false }).limit(100),
  ])
  const links = ((rows ?? []) as Link_[]).sort((a, b) => Number(b.status === 'waiting') - Number(a.status === 'waiting'))
  const bankName = new Map((banks ?? []).map(b => [b.id, b.name]))
  const sellerName = new Map((sellers ?? []).map(s => [s.id, s.name]))
  const waiting = links.filter(l => l.status === 'waiting').length
  return (
    <div className="fixed inset-0 z-40 flex items-start justify-center overflow-y-auto p-4 sm:p-8">
      <Link href={back} scroll={false} aria-label="Fechar" className="fixed inset-0 bg-ink/30" />
      <div role="dialog" aria-modal="true" aria-label="Associar proposta" className="relative w-full max-w-2xl rounded-[14px] border border-line bg-surface p-5 shadow-2xl">
        <div className="mb-3 flex items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-ink">Associar proposta</h2>
            <p className="mt-0.5 text-sm text-ink-soft">Digitou uma proposta no banco? Diga quem vendeu. Quando o contrato chegar ao Corban (importação ou cadastro), o vendedor entra sozinho, no lugar do vendedor da planilha.</p>
          </div>
          <Link href={back} scroll={false} aria-label="Fechar" className="inline-flex size-9 shrink-0 items-center justify-center rounded-[10px] border border-line text-ink-soft hover:bg-surface-muted"><X size={16} aria-hidden /></Link>
        </div>
        <Suspense fallback={null}><FlashBanner /></Suspense>
        <form action={linkSeller} className="grid gap-3 rounded-[12px] border border-line p-4 sm:grid-cols-2">
          <input type="hidden" name="back" value={back} />
          <label className={lbl}>Banco<select name="bank_id" required defaultValue="" className="field mt-1.5"><option value="" disabled>Escolha</option>{(banks ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          <label className={lbl}>Nº da proposta / ADE<input name="ade" maxLength={40} placeholder="Ex.: 143413" className="field mt-1.5" /></label>
          <label className={lbl}>CPF do cliente<input name="cpf" inputMode="numeric" maxLength={14} placeholder="000.000.000-00" className="field mt-1.5" /></label>
          <label className={lbl}>Nome do cliente<input name="client_name" maxLength={160} className="field mt-1.5" /></label>
          <label className={`${lbl} sm:col-span-2`}>Vendedor<select name="seller_id" required defaultValue="" className="field mt-1.5"><option value="" disabled>Escolha</option>
            {(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}{s.name}</option>)}</select></label>
          <p className="text-xs text-muted sm:col-span-2">Informe o nº da proposta/ADE, o CPF ou os dois. Pelo nº o contrato é achado mesmo se já estiver no Corban; pelo CPF, só um contrato novo desse cliente nesse banco (contratos antigos dele não mudam).</p>
          <div className="sm:col-span-2"><SubmitButton className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Associando...">Associar</SubmitButton></div>
        </form>

        <h3 className="mt-5 text-sm font-semibold text-ink">Associações <span className="font-normal text-muted">· {waiting} aguardando · {links.length - waiting} usadas ou canceladas (últimas 100)</span></h3>
        <ul className="mt-2 grid gap-2">
          {links.map(l => {
            const [st, tone] = STATUS[l.status] ?? [l.status, 'neutral']
            return (
              <li key={l.id} className="rounded-[10px] border border-line px-3 py-2 text-sm">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  <span className="font-medium text-ink">{l.client_name ?? 'Cliente'}</span>
                  <span className="text-ink-soft">{bankName.get(l.org_bank_id) ?? 'Banco'}{l.ade ? ` · nº ${l.ade}` : ''}{l.cpf ? ` · CPF ${formatCpf(l.cpf)}` : ''}</span>
                  <span className="text-ink-soft">→ {sellerName.get(l.seller_id) ?? 'Vendedor'}</span>
                  <Badge tone={tone}>{st}</Badge>
                  {l.proposal_id && <Link href={`/app/propostas/${l.proposal_id}`} className="text-brand hover:underline">ver contrato{l.matched_by ? ` (achado pelo ${l.matched_by === 'ade' ? 'nº' : 'CPF'})` : ''}</Link>}
                  <span className="ml-auto text-xs text-muted">{new Date(l.created_at).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</span>
                </div>
                {l.cancel_reason && <p className="mt-1 text-xs text-muted">Motivo: {l.cancel_reason}</p>}
                {l.status === 'waiting' && (
                  <details className="mt-1">
                    <summary className="cursor-pointer text-xs text-[#B91C1C]">Cancelar associação</summary>
                    <form action={cancelLink} className="mt-2 flex flex-wrap items-end gap-2">
                      <input type="hidden" name="link_id" value={l.id} /><input type="hidden" name="back" value={back} />
                      <label className="flex-1 text-xs text-ink-soft">Motivo<input name="reason" required minLength={3} maxLength={300} className="field mt-1" /></label>
                      <SubmitButton className="inline-flex h-10 items-center rounded-[10px] border border-line bg-surface px-3 text-sm text-[#B91C1C] hover:bg-surface-muted" pendingText="...">Cancelar</SubmitButton>
                    </form>
                  </details>
                )}
              </li>
            )
          })}
          {!links.length && <li className="text-sm text-muted">Nenhuma associação ainda.</li>}
        </ul>
      </div>
    </div>
  )
}
