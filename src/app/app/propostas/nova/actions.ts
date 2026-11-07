'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { originDetails } from '@/lib/proposals/origin'
import { isUuid } from '@/lib/team'
import { acceptsTerm, termsLabel, type TermRange } from '@/lib/commission/tableTerms'

// prazos: the terms the chosen table accepts, shown next to the term field when the typed one is outside them.
const back = (code: FeedbackCode, cliente?: string, prazos?: string): never => {
  const q = new URLSearchParams()
  if (cliente && isUuid(cliente)) q.set('cliente', cliente)
  if (prazos) q.set('prazos', prazos)
  const qs = q.toString()
  redirect(feedbackUrl(`/app/propostas/nova${qs ? `?${qs}` : ''}`, code))
}

// Direct proposal: before digitization (queue) or already digitized with the ADE. Same bank + ADE opens the existing one.
export async function createDirectProposal(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const text = (k: string) => String(formData.get(k) ?? '').trim()
  const client = text('customer_id')
  const table = text('table_version_id')
  const contractType = text('contract_type_id')
  const seller = text('seller_id')
  const stage = text('stage') === 'submitted' ? 'submitted' : 'digitization_queue'
  const ade = text('ade')
  const origin = originDetails(formData)
  if (!origin.ok) return back('erro:saldo_devedor_invalido', client)
  if (!isUuid(client) || !isUuid(table) || !isUuid(contractType) || (seller && !isUuid(seller))) return back('erro:requisicao_invalida', client)
  const requested = parseMoneyInput(formData.get('requested_amount'))
  const released = parseMoneyInput(formData.get('released_amount'))
  const installment = parseMoneyInput(formData.get('installment_amount'))
  if (requested === 'invalid' || released === 'invalid' || installment === 'invalid') return back('erro:valor_invalido', client)
  if (!requested && !released) return back('erro:valor_invalido', client)
  const termText = text('term')
  const term = termText ? Number.parseInt(termText, 10) : null
  if (termText && (!Number.isInteger(term) || term! < 1 || term! > 420)) return back('erro:prazo_invalido', client)
  if (stage === 'submitted' && !ade) return back('erro:ade_obrigatorio', client)
  // The term must fit a line of the chosen table (audit 06/11/2026, E2: a 200-month contract on a 12-120 table was saved
  // and its commission was born uncalculated). Lines of the chosen contract type count; a table without lines of that
  // type is checked against all its lines; a table without terms is not checked.
  if (term !== null) {
    const { data: lines } = await supabase.from('commercial_conditions').select('contract_type_id,term,term_min,term_max').eq('product_table_version_id', table)
    const rangesOf = (rows: { term: number | null; term_min: number | null; term_max: number | null }[]) => rows
      .map(l => ({ min: l.term_min ?? l.term, max: l.term_max ?? l.term }))
      .filter((r): r is TermRange => r.min !== null && r.max !== null)
    const ofType = rangesOf((lines ?? []).filter(l => l.contract_type_id === contractType))
    const ranges = ofType.length ? ofType : rangesOf(lines ?? [])
    if (ranges.length && !acceptsTerm(ranges, term)) return back('erro:prazo_fora_da_tabela', client, termsLabel(ranges))
  }

  const { data, error } = await supabase.rpc('create_direct_proposal', {
    p_org: organization.id, p_customer_id: client, p_table_version_id: table, p_seller_id: seller || null,
    p_requested_amount: requested, p_released_amount: released, p_installment_amount: installment, p_term: term,
    p_ade: ade || null, p_stage: stage, p_contract_type_id: contractType, p_details: origin.details,
  })
  if (error) {
    const m = error.message ?? ''
    if (/ade_required/.test(m)) return back('erro:ade_obrigatorio', client)
    if (/invalid_ade/.test(m)) return back('erro:ade_invalido', client)
    if (/invalid_amount|amount_required/.test(m)) return back('erro:valor_invalido', client)
    if (/invalid_term/.test(m)) return back('erro:prazo_invalido', client)
    if (/contract_type_not_in_table|contract_type_not_found/.test(m)) return back('erro:tipo_fora_da_tabela', client)
    if (/invalid_outstanding_balance|invalid_origin/.test(m)) return back('erro:saldo_devedor_invalido', client)
    return back(classifyDbFeedback(error), client)
  }
  const row = (Array.isArray(data) ? data[0] : data) as { proposal_id: string; duplicate: boolean } | null
  if (!row) return back('erro:inesperado', client)
  revalidatePath('/app/propostas')
  redirect(feedbackUrl(`/app/propostas/${row.proposal_id}`, row.duplicate ? 'ok:proposta_ja_existia' : 'ok:proposta_criada'))
}
