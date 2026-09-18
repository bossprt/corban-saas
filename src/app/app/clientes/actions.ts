'use server'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

export async function createCustomer(formData: FormData) {
  const { supabase, membership, user } = await requireAppContext()
  const fullName = String(formData.get('full_name') ?? '').trim()
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  const phone = String(formData.get('phone') ?? '').trim() || null
  const email = String(formData.get('email') ?? '').trim().toLowerCase() || null
  if (fullName.length < 3) throw new Error('Nome inválido')
  if (cpf.length !== 11) throw new Error('CPF deve ter 11 dígitos')
  if (email && !email.includes('@')) throw new Error('E-mail inválido')
  const { data, error } = await supabase.from('clients').insert({
    organization_id: membership.organization_id, full_name: fullName, cpf, phone, email, original_source: 'corban_os'
  }).select('id').single()
  if (error) throw new Error(error.code === '23505' ? 'CPF já cadastrado neste tenant' : 'Não foi possível cadastrar o cliente')
  await supabase.from('customer_timeline_events').insert({
    organization_id: membership.organization_id, customer_id: data.id, event_type: 'customer.created', source: 'corban_os', actor_user_id: user.id
  })
  revalidatePath('/app/clientes'); revalidatePath('/app')
}
