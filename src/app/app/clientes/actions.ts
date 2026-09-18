'use server'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

export async function createCustomer(formData: FormData) {
  const { supabase } = await requireAppContext()
  const fullName = String(formData.get('full_name') ?? '').trim()
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  const phone = String(formData.get('phone') ?? '').trim() || null
  const email = String(formData.get('email') ?? '').trim().toLowerCase() || null
  if (fullName.length < 3) throw new Error('Nome inválido')
  if (cpf.length !== 11) throw new Error('CPF deve ter 11 dígitos')
  if (email && !email.includes('@')) throw new Error('E-mail inválido')
  const { error } = await supabase.rpc('create_customer_with_timeline', {
    p_full_name: fullName,
    p_cpf: cpf,
    p_phone: phone,
    p_email: email,
    p_original_source: 'corban_os'
  })
  if (error) throw new Error(error.code === '23505' ? 'CPF já cadastrado neste tenant' : 'Não foi possível cadastrar o cliente')
  revalidatePath('/app/clientes'); revalidatePath('/app')
}
