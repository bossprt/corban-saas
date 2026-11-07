'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { feedbackUrl } from '@/lib/feedback'
import { bankAccountOf } from '@/lib/finBankAccounts'
import { buildBulkItems, bulkReceiptError } from '@/lib/receipts/bulk'

export type BulkState = { error: string | null }

// $ Several à vista receipts at once (06/11/2026). The database runs public.register_manual_receipt for each contract
// (expected value, duplicates, reconciliation, finance entry) inside one transaction: one failure, nothing recorded.
export async function registerReceiptsBulk(_: BulkState, f: FormData): Promise<BulkState> {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.approve')) return { error: 'Seu perfil não pode registrar recebimentos.' }
  const built = buildBulkItems(f.getAll('sel').map(String), id => f.get(`amount_${id}`))
  if (!built.ok) return { error: built.error }
  const receivedOn = String(f.get('received_on') ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(receivedOn)) return { error: 'Informe a data em que o dinheiro caiu.' }
  const { error } = await supabase.rpc('register_manual_receipts_bulk', {
    p_org: organization.id, p_items: built.items, p_received_on: receivedOn,
    p_bank_account: bankAccountOf(f), p_note: String(f.get('note') ?? '').trim().slice(0, 100),
  })
  if (error) return { error: bulkReceiptError(error.message) }
  revalidatePath('/app/financeiro', 'layout')
  const back = String(f.get('return_to') ?? '')
  return redirect(feedbackUrl(back.startsWith('/app/financeiro/a-receber') && !back.includes('//') ? back : '/app/financeiro/a-receber', 'ok:recebimentos_registrados'))
}
