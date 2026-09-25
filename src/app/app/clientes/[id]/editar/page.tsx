import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { updateCustomer } from '../../actions'
import { ClientForm, type ClientFormValues } from '../../ClientForm'
import type { AccountRow, RegistrationRow } from '../../RepeatableBlocks'

// Edit a client in the same form as the registration (owner decision), with every block prefilled.
export default async function EditClientPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'clientes.edit')) {
    return <section><PageHeader title="Editar cadastro" /><Card className="p-5 text-sm text-ink-soft">Seu papel não pode editar clientes.</Card></section>
  }
  const [{ data: client }, { data: address }, { data: accounts }, { data: registrations }, { data: agreements }] = await Promise.all([
    supabase.from('clients').select('id,full_name,cpf,phone,email,birth_date,father_name,mother_name,rg_number,rg_issuer,rg_state,rg_issued_on,gender,marital_status,birthplace_city,birthplace_state,whatsapp')
      .eq('id', id).is('deleted_at', null).maybeSingle(),
    supabase.from('customer_addresses').select('postal_code,street,number,complement,neighborhood,city,state').eq('customer_id', id).eq('is_primary', true).limit(1).maybeSingle(),
    supabase.from('customer_bank_accounts').select('id,bank_code,bank_name,branch,account_number,account_digit,account_type,is_primary').eq('customer_id', id).order('is_primary', { ascending: false }).order('created_at'),
    supabase.from('client_registrations').select('id,agreement_id,agency_name,registration_number,status,margin_amount,margin_as_of,portal_login,has_portal_password').eq('customer_id', id).order('status').order('created_at'),
    supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name'),
  ])
  if (!client) notFound()

  return (
    <section>
      <Link href={`/app/clientes/${id}`} className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Voltar à ficha</Link>
      <PageHeader title="Editar cadastro" description={client.full_name} />
      <Card className="p-5">
        <ClientForm mode="edit" action={updateCustomer} client={client as ClientFormValues} canEdit agreements={agreements ?? []}
          accounts={(accounts ?? []) as AccountRow[]} registrations={(registrations ?? []) as RegistrationRow[]}
          address={address ? { zip: address.postal_code ?? '', street: address.street ?? '', number: address.number ?? '', complement: address.complement ?? '', district: address.neighborhood ?? '', city: address.city ?? '', state: address.state ?? '' } : undefined} />
      </Card>
    </section>
  )
}
