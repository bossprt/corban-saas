import { Suspense } from 'react'
import Link from 'next/link'
import { FlashBanner } from '@/components/FlashBanner'
import { ExternalLink, X } from 'lucide-react'
import { Badge } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { brlText } from '@/lib/receipts/format'
import { decimalBr } from '@/lib/commission/tableValues'
import { add, fromDecimalString, mul, toDecimalString } from '@/lib/commission/money'
import { CALC_FAILURE } from '@/app/app/propostas/[id]/CommissionCard'
import { quickAde, quickCalc, quickData, quickNote, quickPayout, quickSeller } from './quick-actions'

export const QUICK_ACTIONS = ['vendedor', 'comissao', 'calcular', 'dados', 'ade', 'documentos', 'observacoes'] as const
export type QuickAction = (typeof QUICK_ACTIONS)[number]
const TITLE: Record<QuickAction, string> = {
  vendedor: 'Alterar vendedor', comissao: 'Comissão', calcular: 'Cadastrar comissão', dados: 'Dados do contrato', ade: 'Alterar ADE',
  documentos: 'Documentos', observacoes: 'Observações',
}
const COMPONENT_LABEL: Record<string, string> = { upfront: 'À vista', deferred: 'Diferido', bonus_1: 'Bônus 1', bonus_2: 'Bônus 2', bonus_3: 'Bônus 3', plastic: 'Plástico', insurance_fixed: 'Seguro' }
const lbl = 'block text-[13px] font-medium text-ink-soft'
const primary = 'inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost = 'inline-flex h-10 items-center rounded-[10px] border border-line bg-surface px-4 text-sm text-ink hover:bg-surface-muted'
const money = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : brlText(String(v)))
const DOC_STATUS: Record<string, string> = { pending: 'Falta', attached: 'Anexado, falta validar', validated: 'Validado', rejected: 'Recusado', waived: 'Dispensado' }

type P = { id: string; external_proposal_id: string | null; status: string; requested_amount: string | null; released_amount: string | null; installment_amount: string | null
  term: number | null; paid_to_client_on: string | null; customer_snapshot: { full_name?: string } | null; seller_id: string | null; product_table_version_id: string | null; contract_type_id: string | null }

// One quick change of one contract, as a window over the Contratos list (owner, 08/10/2026). The contract is always
// spelled out on top, so it is clear which one is being changed. back: the list with its filters (forms return there).
export async function QuickModal({ id, acao, back, canEdit, finance, owner }: { id: string; acao: QuickAction; back: string; canEdit: boolean; finance: boolean; owner: boolean }) {
  const { supabase } = await requireAppContext()
  const { data } = await supabase.from('proposals_v2')
    .select('id,external_proposal_id,status,requested_amount,released_amount,installment_amount,term,paid_to_client_on,customer_snapshot,seller_id,product_table_version_id,contract_type_id')
    .eq('id', id).maybeSingle()
  const p = data as P | null
  const paid = p?.status === 'paid'
  const hidden = <><input type="hidden" name="proposal_id" value={id} /><input type="hidden" name="back" value={back} /></>
  const reason = (required: boolean) => (
    <label className={lbl}>Motivo{required ? '' : ' (opcional)'}<input name="reason" required={required} minLength={required ? 3 : undefined} maxLength={500} placeholder={required ? 'Obrigatório: contrato pago' : 'Ex.: vendedor corrigido'} className="field mt-1.5" /></label>
  )
  const buttons = (label: string) => <div className="flex flex-wrap gap-2"><SubmitButton className={primary} pendingText="Salvando...">{label}</SubmitButton><Link href={back} scroll={false} className={ghost}>Voltar</Link></div>

  let body: React.ReactNode = <p className="text-sm text-muted">Contrato não encontrado.</p>
  if (p && acao === 'vendedor') {
    const { data: sellers } = await supabase.from('commercial_sellers').select('id,name,code,is_active').eq('is_active', true).order('name')
    body = canEdit ? (
      <form action={quickSeller} className="grid gap-3">{hidden}
        <label className={lbl}>Novo vendedor<select name="seller_id" required defaultValue={p.seller_id ?? ''} className="field mt-1.5"><option value="" disabled>Escolha</option>
          {(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}{s.name}</option>)}</select></label>
        {reason(paid)}
        <p className="text-xs text-muted">A comissão é recalculada com o grupo do novo vendedor. A troca fica no histórico do contrato.</p>
        {buttons('Salvar e recalcular')}
      </form>) : <p className="text-sm text-muted">Sem permissão para alterar o vendedor.</p>
  } else if (p && acao === 'dados') {
    body = canEdit ? (
      <form action={quickData} className="grid gap-3">{hidden}
        <div className="grid gap-3 sm:grid-cols-2">
          <label className={lbl}>Valor bruto (R$)<input name="requested_amount" inputMode="decimal" defaultValue={p.requested_amount ? decimalBr(String(p.requested_amount)) : ''} className="field mt-1.5" /></label>
          <label className={lbl}>Valor líquido (R$)<input name="released_amount" inputMode="decimal" defaultValue={p.released_amount ? decimalBr(String(p.released_amount)) : ''} className="field mt-1.5" /></label>
          <label className={lbl}>Parcela (R$)<input name="installment_amount" inputMode="decimal" defaultValue={p.installment_amount ? decimalBr(String(p.installment_amount)) : ''} className="field mt-1.5" /></label>
          <label className={lbl}>Prazo (meses)<input name="term" inputMode="numeric" defaultValue={p.term ?? ''} className="field mt-1.5" /></label>
          {paid && <label className={lbl}>Pago ao cliente em<input type="date" name="paid_to_client_on" defaultValue={p.paid_to_client_on ?? ''} className="field mt-1.5" /></label>}
        </div>
        {reason(paid)}
        <p className="text-xs text-muted">Tabela, tipo e saldo devedor: <Link href={`/app/propostas/${id}#contrato`} className="text-brand hover:underline">abrir o contrato</Link>.</p>
        {buttons('Salvar e recalcular')}
      </form>) : <p className="text-sm text-muted">Sem permissão para alterar o contrato.</p>
  } else if (p && acao === 'ade') {
    body = canEdit ? (
      <form action={quickAde} className="grid gap-3">{hidden}
        <label className={lbl}>Nova ADE (nº do contrato no banco)<input name="ade" required maxLength={40} defaultValue={p.external_proposal_id ?? ''} className="field mt-1.5" /></label>
        {reason(paid)}
        <p className="text-xs text-muted">O número anterior fica no histórico e continua achando o contrato nos relatórios do banco. ADE de outro contrato é recusada.</p>
        {buttons('Salvar ADE')}
      </form>) : <p className="text-sm text-muted">Sem permissão para alterar a ADE.</p>
  } else if (p && (acao === 'comissao' || acao === 'calcular')) {
    const { data: calc } = finance ? await supabase.from('proposal_commission_calcs').select('id').eq('proposal_id', id).eq('status', 'active').maybeSingle() : { data: null }
    if (!finance) body = <p className="text-sm text-muted">A comissão aparece para o financeiro.</p>
    else if (!calc) {
      // Not calculated: the reason of the last try and the one field (or screen) that fixes it.
      const { data: failure } = await supabase.from('contract_events').select('detail').eq('proposal_id', id).eq('kind', 'calc_failed').order('created_at', { ascending: false }).limit(1).maybeSingle()
      const code = String((failure?.detail as { code?: string } | null)?.code ?? '')
      let fix: React.ReactNode = null
      if (code === 'proposal_without_seller' || !p.seller_id) {
        const { data: sellers } = await supabase.from('commercial_sellers').select('id,name,code').eq('is_active', true).order('name')
        fix = canEdit && (
          <form action={quickSeller} className="grid gap-3">{hidden}
            <label className={lbl}>Vendedor do contrato<select name="seller_id" required defaultValue="" className="field mt-1.5"><option value="" disabled>Escolha</option>
              {(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}{s.name}</option>)}</select></label>
            {reason(paid)}
            {buttons('Salvar e calcular')}
          </form>)
      } else if (code === 'condition_ambiguous' && p.product_table_version_id) {
        const { data: lines } = await supabase.from('commercial_conditions').select('id,term_min,term_max,amount_min,amount_max,rate')
          .eq('product_table_version_id', p.product_table_version_id).eq('contract_type_id', p.contract_type_id ?? '')
        const fits = (lines ?? []).filter(l => p.term === null || (p.term >= l.term_min && p.term <= l.term_max))
        fix = canEdit && (
          <form action={quickCalc} className="grid gap-3">{hidden}
            <fieldset className="grid gap-1.5"><legend className={lbl}>Qual linha da tabela vale para este contrato?</legend>
              {fits.map(l => <label key={l.id} className="flex items-center gap-2 text-sm text-ink"><input type="radio" name="condition_id" value={l.id} required className="accent-[var(--brand)]" />
                {l.term_min === l.term_max ? `${l.term_min}x` : `${l.term_min} a ${l.term_max}x`}{l.amount_min ? ` · ${money(l.amount_min)} a ${money(l.amount_max)}` : ''}{l.rate ? ` · taxa ${decimalBr(String(l.rate))}%` : ''}</label>)}
            </fieldset>
            {buttons('Calcular com esta linha')}
          </form>)
      } else {
        const { data: v } = p.product_table_version_id ? await supabase.from('product_table_versions').select('product_table_id').eq('id', p.product_table_version_id).maybeSingle() : { data: null }
        const where = code === 'seller_without_group' ? { href: '/app/cadastros/vendedores', label: 'Abrir vendedores' }
          : code === 'group_rule_missing' ? { href: '/app/comercial/grupos', label: 'Abrir grupos de vendedores' }
          : v ? { href: `/app/comercial/tabelas/${v.product_table_id}`, label: 'Abrir a tabela do contrato' } : null
        fix = (
          <form action={quickCalc} className="grid gap-3">{hidden}
            {where && <p className="text-sm text-ink-soft">Corrija o cadastro em <Link href={where.href} className="text-brand hover:underline">{where.label}</Link> e depois clique em calcular.</p>}
            {buttons('Calcular agora')}
          </form>)
      }
      body = <div className="grid gap-3">
        <p role="alert" className="rounded-[10px] border border-[#FCD34D] bg-[#FFFBEB] px-3 py-2 text-sm text-[#92400E]">Comissão não calculada{code ? `: ${CALC_FAILURE[code] ?? 'erro no cálculo'}` : ''}.</p>
        {fix}
      </div>
    } else {
      const [{ data: lineRows }, { data: payoutRows }] = await Promise.all([
        supabase.from('proposal_commission_lines').select('line_kind,amount,multiplier').eq('calc_id', calc.id),
        supabase.rpc('contract_payout', { p_proposal: id }),
      ])
      // Sum of one kind over the parts (à vista, diferido...), exact decimals.
      const lineSum = (kind: string) => toDecimalString((lineRows ?? []).filter(l => l.line_kind === kind)
        .reduce((a, l) => add(a, mul(fromDecimalString(String(l.amount)), fromDecimalString(String(l.multiplier ?? 1)))), fromDecimalString('0')), 2)
      const payouts = (payoutRows ?? []) as { component_key: string; received: string; rule_amount: string; value_kind: string | null; value: string | null; payable: string; overridden: boolean; locked: boolean }[]
      body = <div className="grid gap-3">
        <dl className="grid grid-cols-2 gap-2 text-sm">
          <div><dt className="text-xs text-muted">Empresa recebe</dt><dd className="num font-semibold text-ink">{money(lineSum('received'))}</dd></div>
          <div><dt className="text-xs text-muted">Imposto</dt><dd className="num text-ink">{money(lineSum('tax'))}</dd></div>
          {payouts.map(x => <div key={x.component_key} className="col-span-2 flex flex-wrap items-center gap-2 border-t border-line pt-2"><span className="text-xs text-muted">Vendedor recebe ({COMPONENT_LABEL[x.component_key] ?? x.component_key})</span>
            <span className="num font-semibold text-ink">{money(x.payable)}</span>{x.overridden && owner && <Badge tone="pending">Alterado · regra {money(x.rule_amount)}</Badge>}{x.locked && <Badge tone="received">Já pago ao vendedor</Badge>}</div>)}
        </dl>
        {owner && payouts.filter(x => !x.locked).map(x => (
          <details key={x.component_key} open={payouts.filter(y => !y.locked).length === 1} className="rounded-[10px] border border-line p-3">
          <summary className="cursor-pointer text-sm font-medium text-ink">Alterar repasse do vendedor — {COMPONENT_LABEL[x.component_key] ?? x.component_key}</summary>
          <form action={quickPayout} className="mt-3 grid gap-3">{hidden}<input type="hidden" name="component" value={x.component_key} />
            <div className="grid gap-3 sm:grid-cols-2">
              <label className={lbl}>Tipo<select name="kind" defaultValue={x.value_kind ?? 'percentage'} className="field mt-1.5"><option value="percentage">% da base</option><option value="fixed_brl">Valor fixo (R$)</option></select></label>
              <label className={lbl}>Valor<input name="value" required inputMode="decimal" placeholder="10 ou 500,00" className="field mt-1.5" /></label>
            </div>
            <label className={lbl}>Motivo<input name="reason" required minLength={3} maxLength={500} placeholder="Obrigatório" className="field mt-1.5" /></label>
            {buttons('Salvar repasse')}
          </form>
          </details>
        ))}
        {!owner && <p className="text-xs text-muted">Só o Administrador altera o repasse do vendedor.</p>}
        <form action={quickCalc}>{hidden}<SubmitButton className={ghost} pendingText="Recalculando...">Recalcular pela tabela</SubmitButton></form>
      </div>
    }
  } else if (p && acao === 'documentos') {
    const { data: reqs } = await supabase.from('proposal_document_requirements').select('id,label_snapshot,required_snapshot,status').eq('proposal_id', id).order('label_snapshot')
    body = <div className="grid gap-3">
      {(reqs ?? []).length ? <ul className="grid gap-1.5 text-sm">{(reqs ?? []).map(r => <li key={r.id} className="flex items-center justify-between gap-2 border-b border-line pb-1.5"><span className="text-ink">{r.label_snapshot}{r.required_snapshot ? ' *' : ''}</span><Badge tone={r.status === 'validated' || r.status === 'waived' ? 'received' : 'pending'}>{DOC_STATUS[r.status] ?? r.status}</Badge></li>)}</ul>
        : <p className="text-sm text-muted">Este contrato não tem lista de documentos.</p>}
      <div className="flex gap-2"><Link href={`/app/propostas/${id}#documentos`} className={primary}>Anexar ou validar no contrato</Link><Link href={back} scroll={false} className={ghost}>Voltar</Link></div>
    </div>
  } else if (p && acao === 'observacoes') {
    const { data: notes } = await supabase.from('contract_events').select('id,reason,created_at').eq('proposal_id', id).eq('kind', 'note').order('created_at', { ascending: false }).limit(20)
    body = <div className="grid gap-3">
      <form action={quickNote} className="grid gap-2">{hidden}
        <label className={lbl}>Nova observação<textarea name="note" required maxLength={2000} rows={3} className="field mt-1.5" /></label>
        {buttons('Registrar observação')}
      </form>
      <ol className="grid gap-2 text-sm">{(notes ?? []).map(n => <li key={n.id} className="border-t border-line pt-2"><span className="block text-xs text-muted">{new Date(n.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</span><span className="whitespace-pre-wrap text-ink-soft">{n.reason}</span></li>)}</ol>
    </div>
  }

  return (
    <div className="fixed inset-0 z-40 flex items-start justify-center overflow-y-auto p-4 sm:p-8">
      <Link href={back} scroll={false} aria-label="Fechar" className="fixed inset-0 bg-ink/30" />
      <div role="dialog" aria-modal="true" aria-label={TITLE[acao]} className="relative w-full max-w-lg rounded-[14px] border border-line bg-surface p-5 shadow-2xl">
        <div className="mb-4 flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h2 className="text-lg font-semibold text-ink">{TITLE[acao]}</h2>
            {p && <p className="mt-0.5 text-sm text-ink-soft"><span className="font-medium text-ink">{p.customer_snapshot?.full_name ?? 'Cliente'}</span>{p.external_proposal_id ? ` · ADE ${p.external_proposal_id}` : ''} · {money(p.requested_amount ?? p.released_amount)}{p.term ? ` em ${p.term}x` : ''}</p>}
          </div>
          <span className="flex items-center gap-1">
            <Link href={`/app/propostas/${id}`} aria-label="Abrir contrato completo" className="inline-flex size-9 items-center justify-center rounded-[10px] text-muted hover:bg-surface-muted hover:text-ink"><ExternalLink size={16} aria-hidden /></Link>
            <Link href={back} scroll={false} aria-label="Fechar" className="inline-flex size-9 items-center justify-center rounded-[10px] border border-line text-ink-soft hover:bg-surface-muted"><X size={16} aria-hidden /></Link>
          </span>
        </div>
        <Suspense fallback={null}><FlashBanner /></Suspense>
        {body}
      </div>
    </div>
  )
}
