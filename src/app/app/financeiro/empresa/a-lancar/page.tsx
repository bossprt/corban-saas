import Link from 'next/link'
import { Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, dayLabel } from '@/lib/finance/labels'
import { FinanceTabs } from '../FinanceTabs'
import { postPending, setAutoPost } from '../actions'

type Pending = { kind: string; source_ref: string; happened_on: string | null; description: string; amount: string; proposal_id: string | null }

// Commission received and payouts paid that are not in the company finance yet. Automatic by default (owner decision);
// the owner may switch to posting them one by one here.
export default async function PendingPostingsPage() {
  const { supabase, organization, access, membership } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="A lançar" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  await supabase.rpc('fin_setup', { p_org: organization.id })
  const [{ data: settings }, { data: pending }] = await Promise.all([
    supabase.from('fin_settings').select('auto_post').maybeSingle(),
    supabase.rpc('fin_pending_postings', { p_org: organization.id }),
  ])
  const auto = settings?.auto_post ?? true
  const edit = can(access, 'financeiro.edit')
  const rows = (pending ?? []) as Pending[]

  return (
    <section>
      <PageHeader title="Comissões e repasses a lançar" description="A comissão recebida dos bancos entra como receita e o repasse pago aos vendedores entra como custo." />
      <FinanceTabs current="/app/financeiro/empresa/a-lancar" />
      <Card className="mb-4 flex flex-wrap items-center justify-between gap-3 p-5">
        <p className="text-sm text-ink-soft">{auto ? <><strong className="text-ink">Automático:</strong> cada comissão confirmada e cada repasse pago entram sozinhos no financeiro.</> : <><strong className="text-ink">Manual:</strong> nada entra sozinho; lance cada um nesta lista.</>}</p>
        {membership.role === 'admin' && (
          <form action={setAutoPost}>
            <input type="hidden" name="auto" value={auto ? 'false' : 'true'} />
            <SubmitButton className="h-10 rounded-[10px] border border-line-strong bg-surface px-4 text-sm text-ink hover:bg-surface-muted" pendingText="...">{auto ? 'Passar a lançar manualmente' : 'Voltar ao automático'}</SubmitButton>
          </form>
        )}
      </Card>
      <Card className="overflow-hidden">
        <CardHeader title={`A lançar (${rows.length})`} />
        {!rows.length ? <p className="px-5 pb-5 text-sm text-muted">Tudo lançado.</p> : (
          <table className="w-full text-left text-sm">
            <thead className="bg-surface-muted text-xs text-muted"><tr><th className="px-4 py-2">Data</th><th className="px-4 py-2">O quê</th><th className="px-4 py-2 text-right">Valor</th><th className="px-4 py-2"><span className="sr-only">Lançar</span></th></tr></thead>
            <tbody>
              {rows.slice(0, 300).map(r => (
                <tr key={`${r.kind}-${r.source_ref}`} className="border-t border-line">
                  <td className="num px-4 py-2 text-ink-soft">{dayLabel(r.happened_on)}</td>
                  <td className="px-4 py-2">{r.proposal_id ? <Link href={`/app/propostas/${r.proposal_id}`} className="text-brand hover:underline">{r.description}</Link> : r.description}</td>
                  <td className={`num px-4 py-2 text-right ${Number(r.amount) > 0 ? 'text-[#15803D]' : 'text-ink'}`}>{Number(r.amount) > 0 ? '+' : '−'} {brl(Math.abs(Number(r.amount)))}</td>
                  <td className="px-4 py-2 text-right">{edit && (
                    <form action={postPending}><input type="hidden" name="kind" value={r.kind} /><input type="hidden" name="ref" value={r.source_ref} />
                      <SubmitButton className="h-8 rounded-lg bg-brand px-3 text-xs font-semibold text-white" pendingText="...">Lançar</SubmitButton></form>
                  )}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Card>
    </section>
  )
}
