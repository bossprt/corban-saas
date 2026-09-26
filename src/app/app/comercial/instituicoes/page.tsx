import Link from 'next/link'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { decimalBr } from '@/lib/commission/tableValues'
import { createBank, renameCatalogItem, setActive } from '../actions'
import { saveBankIrWithheld } from './actions'

const lbl = 'text-[13px] font-medium text-ink-soft'
const ghost = 'h-9 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted'

// Banks the company works with. Whether the company pays tax on a bank's production is read from the "Imposto" column
// of its published tables (ADR-0037), never typed here; the IR the bank withholds at source is typed here.
export default async function BanksPage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Bancos" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const [{ data: rows }, { data: situation }] = await Promise.all([
    supabase.from('organization_banks').select('id,name,is_active,ir_withheld_pct').order('name'),
    supabase.rpc('bank_tax_situation', { p_org: membership.organization_id }),
  ])
  const tax = new Map(((situation ?? []) as { bank_id: string; taxed_lines: number; untaxed_lines: number }[]).map(s => [s.bank_id, s]))
  const active = (rows ?? []).filter(r => r.is_active).length

  const taxBadge = (bankId: string) => {
    const s = tax.get(bankId)
    if (!s) return <Badge tone="neutral">Sem tabela publicada</Badge>
    if (s.taxed_lines > 0 && s.untaxed_lines > 0) return <Badge tone="pending">Misto: {s.taxed_lines} linha(s) com imposto, {s.untaxed_lines} sem</Badge>
    return s.taxed_lines > 0 ? <Badge tone="brand">Paga imposto</Badge> : <Badge tone="received">Isenta</Badge>
  }

  return (
    <section>
      <Link href="/app/cadastros" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Cadastros</Link>
      <PageHeader title="Bancos" description="Bancos com que a empresa trabalha. O imposto vem da coluna Imposto das tabelas publicadas de cada banco; o IR retido é o que o banco desconta na fonte ao pagar a comissão." />

      {canEdit && <Card className="mb-4">
        <form action={createBank} className="flex flex-wrap items-end gap-2 p-5">
          <input type="hidden" name="return_to" value="/app/comercial/instituicoes" />
          <label className={`${lbl} min-w-64 flex-1`}>Novo banco<input required name="name" maxLength={120} placeholder="Ex.: Daycoval" className="field mt-1.5" /></label>
          <SubmitButton className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Cadastrando...">Cadastrar banco</SubmitButton>
        </form>
      </Card>}

      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Bancos <Badge tone="neutral">{active} ativo(s) de {(rows ?? []).length}</Badge></span>} />
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[720px] text-left text-[13px]">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr><th className="px-5 py-2 font-medium">Banco</th><th className="px-3 py-2 font-medium">Imposto (pelas tabelas)</th><th className="px-3 py-2 font-medium">IR retido na fonte</th>{canEdit && <th className="px-3 py-2" />}</tr>
            </thead>
            <tbody>
              {(rows ?? []).map(b => (
                <tr key={b.id} className="border-t border-line align-top">
                  <td className="px-5 py-3">
                    <span className="flex flex-wrap items-center gap-2 font-semibold text-ink">{b.name}{!b.is_active && <Badge tone="neutral">Inativo</Badge>}</span>
                    <Link href={`/app/comercial/tabelas?banco=${b.id}`} className="text-xs text-brand hover:underline">Ver tabelas</Link>
                  </td>
                  <td className="px-3 py-3">{taxBadge(b.id)}</td>
                  <td className="px-3 py-3">
                    {canEdit ? (
                      <form action={saveBankIrWithheld} className="flex items-center gap-2">
                        <input type="hidden" name="bank_id" value={b.id} />
                        <input name="ir_withheld_pct" aria-label={`IR retido de ${b.name}`} inputMode="decimal" defaultValue={Number(b.ir_withheld_pct) ? decimalBr(String(b.ir_withheld_pct)) : ''} placeholder="0" className="field w-20" />
                        <span className="text-muted">%</span>
                        <SubmitButton className={ghost} pendingText="...">Salvar</SubmitButton>
                      </form>
                    ) : <span className="num">{Number(b.ir_withheld_pct) ? `${decimalBr(String(b.ir_withheld_pct))}%` : 'Não retém'}</span>}
                  </td>
                  {canEdit && <td className="px-3 py-3">
                    <div className="flex flex-wrap items-center justify-end gap-3">
                      <details>
                        <summary className="cursor-pointer text-xs text-muted underline hover:text-ink">Renomear</summary>
                        <form action={renameCatalogItem} className="mt-2 flex gap-2">
                          <input type="hidden" name="return_to" value="/app/comercial/instituicoes" /><input type="hidden" name="kind" value="bank" /><input type="hidden" name="id" value={b.id} />
                          <input required name="name" defaultValue={b.name} aria-label={`Nome de ${b.name}`} className="field" />
                          <SubmitButton className={ghost} pendingText="...">Salvar</SubmitButton>
                        </form>
                      </details>
                      <form action={setActive}>
                        <input type="hidden" name="return_to" value="/app/comercial/instituicoes" /><input type="hidden" name="kind" value="bank" /><input type="hidden" name="id" value={b.id} /><input type="hidden" name="active" value={b.is_active ? 'false' : 'true'} />
                        <SubmitButton className="text-xs text-muted underline hover:text-ink" pendingText="...">{b.is_active ? 'Inativar' : 'Reativar'}</SubmitButton>
                      </form>
                    </div>
                  </td>}
                </tr>
              ))}
              {!rows?.length && <tr><td colSpan={4} className="px-5 py-6 text-center text-muted">Nenhum banco cadastrado.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
