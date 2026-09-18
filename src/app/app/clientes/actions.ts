'use server'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

function isValidCpf(cpf: string) {
  if (!/^\d{11}$/.test(cpf) || /^(\d)\1{10}$/.test(cpf)) return false
  const digit = (length: number) => {
    let sum = 0
    for (let i = 0; i < length; i += 1) sum += Number(cpf[i]) * (length + 1 - i)
    const remainder = (sum * 10) % 11
    return remainder === 10 ? 0 : remainder
  }
  return digit(9) === Number(cpf[9]) && digit(10) === Number(cpf[10])
}

export async function createCustomer(formData: FormData) {
  const { supabase } = await requireAppContext()
  const fullName = String(formData.get('full_name') ?? '').trim()
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  const phone = String(formData.get('phone') ?? '').trim() || null
  const email = String(formData.get('email') ?? '').trim().toLowerCase() || null

  if (fullName.length < 3) throw new Error('Nome inválido')
  if (!isValidCpf(cpf)) throw new Error('CPF inválido')
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('E-mail inválido')

  const { error } = await supabase.rpc('create_customer_with_timeline', {
    p_full_name: fullName,
    p_cpf: cpf,
    p_phone: phone,
    p_email: email,
    p_original_source: 'corban_os'
  })

  if (error) throw new Error(error.code === '23505' ? 'CPF já cadastrado neste tenant' : 'Não foi possível cadastrar o cliente')
  revalidatePath('/app/clientes')
  revalidatePath('/app')
}
