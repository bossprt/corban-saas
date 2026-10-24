import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ArrowLeft, PhoneOff } from 'lucide-react'
import { Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatPhone } from '@/lib/cpf'
import { isPortalUser } from '@/lib/portal'
import { addDndPhone, removeDndPhone } from '../actions'
import { DndImport } from './DndImport'
import { DndSearch } from './DndSearch'
import { LemitImport } from './LemitImport'

const label = 'text-[13px] font-medium text-ink-soft'
const SOURCE_LABEL: Record<string, string> = { manual: 'Marcado à mão', import: 'Lista importada', lemit: 'Não Perturbe SP (Lemit)' }
const day = (iso: string) => new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })

// "Não perturbe" (owner, 20/10/2026): phones whose owner asked not to be contacted. Marked on the lead, added here or
// imported from the lists the banks send. The board and the lead warn; the queue skips them. Nothing is blocked.
export default async function DoNotDisturbPage() {
  const ctx = await requireAppContext()
  if (isPortalUser(ctx.access?.roleKey, ctx.modules)) redirect('/app/portal')
  if (!can(ctx.access, 'leads.view')) redirect('/app/hoje')
  const { supabase, access, membership } = ctx
  const supervisor = can(access, 'leads.approve')
  const admin = membership.role === 'admin'
  // The Lemit list (thousands of phones) is summed up apart; "Últimos marcados" shows the ones marked here or from banks.
  const [{ data: rows }, { count }, { count: lemitCount }, { data: lemitLast }] = await Promise.all([
    supabase.from('do_not_disturb_phones').select('id,phone,source,note,file_name,created_at').is('removed_at', null).neq('source', 'lemit').order('created_at', { ascending: false }).limit(50),
    supabase.from('do_not_disturb_phones').select('id', { count: 'exact', head: true }).is('removed_at', null),
    supabase.from('do_not_disturb_phones').select('id', { count: 'exact', head: true }).is('removed_at', null).eq('source', 'lemit'),
    supabase.from('do_not_disturb_phones').select('file_name,created_at').is('removed_at', null).eq('source', 'lemit').order('created_at', { ascending: false }).limit(1).maybeSingle(),
  ])

  return (
    <section>
      <Link href="/app/crm" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendas</Link>
      <PageHeader title="Não perturbe" description={`${(count ?? 0).toLocaleString('pt-BR')} telefone(s) na lista da empresa. O lead com um desses números aparece marcado e sai da fila; o sistema avisa, quem decide é o vendedor.`} />

      <div className="grid gap-4 lg:grid-cols-[1.4fr_1fr]">
        <Card>
          <CardHeader title="Últimos marcados" />
          <DndSearch />
          <ul className="px-5 py-2">
            {(rows ?? []).length === 0 && <li className="py-3 text-sm text-muted">Nenhum telefone na lista ainda.</li>}
            {(rows ?? []).map(r => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-t border-line py-2.5 text-sm first:border-t-0">
                <span className="min-w-0">
                  <span className="num font-medium text-ink">{formatPhone(r.phone.slice(2))}</span>
                  <span className="block text-xs text-muted">{[SOURCE_LABEL[r.source] ?? r.source, r.file_name, r.note, day(r.created_at)].filter(Boolean).join(' · ')}</span>
                </span>
                {supervisor && (
                  <form action={removeDndPhone}>
                    <input type="hidden" name="phone" value={r.phone} />
                    <SubmitButton pendingText="Retirando..." className="h-8 rounded-md border border-line px-2 text-xs hover:bg-surface-muted">Retirar da lista</SubmitButton>
                  </form>
                )}
              </li>
            ))}
          </ul>
        </Card>

        <div className="grid content-start gap-4">
          {can(access, 'leads.edit') && (
            <Card>
              <CardHeader title="Marcar um telefone" />
              <form action={addDndPhone} className="grid gap-3 px-5 pb-5 pt-3">
                <label className={label}>Telefone com DDD<input name="phone" required inputMode="tel" placeholder="(68) 99999-0000" className="field mt-1.5" /></label>
                <label className={label}>Observação (opcional)<input name="note" maxLength={300} className="field mt-1.5" /></label>
                <SubmitButton pendingText="Salvando..." className="inline-flex h-10 w-fit items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><PhoneOff size={16} aria-hidden />Marcar &quot;Não perturbe&quot;</SubmitButton>
              </form>
            </Card>
          )}
          <Card>
            <CardHeader title="Lista do Lemit (Não Perturbe SP)" />
            <p className="px-5 pt-3 text-sm text-ink-soft">
              {lemitCount ? `${(lemitCount ?? 0).toLocaleString('pt-BR')} telefones · ${[lemitLast?.file_name, lemitLast?.created_at ? `importada em ${day(lemitLast.created_at)}` : null].filter(Boolean).join(' · ')}` : 'Ainda não importada.'}
            </p>
            {admin ? <LemitImport /> : <p className="px-5 pb-5 pt-2 text-xs text-muted">Só o administrador importa a lista do Lemit.</p>}
          </Card>
          {supervisor && (
            <Card>
              <CardHeader title="Importar lista do banco" />
              <DndImport />
            </Card>
          )}
        </div>
      </div>
    </section>
  )
}
