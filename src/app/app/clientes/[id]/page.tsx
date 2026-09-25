import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft, FilePlus2 } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { missingProfileFields, type ProfileFields } from '@/lib/clients/profile'
import { formatCpf, formatPhone } from '@/lib/cpf'
import { proposalStatusLabel } from '@/lib/operational'
import { updateCustomer } from '../actions'
import { ClientForm, type ClientFormValues } from '../ClientForm'
import { BankAccounts, PersonalData, Registrations, type BankAccount, type Registration } from './ProfileSections'

const brl = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))
const day = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR') : '—')
const SOURCE: Record<string, string> = { manual: 'cadastro manual', corban_os: 'cadastro manual', api: 'API', legado: 'legado' }
const source = (s: string | null) => (s ? SOURCE[s] ?? (s.startsWith('lead:') ? `lead (${s.slice(5)})` : s) : '—')
const EVENT: Record<string, string> = { 'customer.created': 'Cliente cadastrado', 'customer.recognized': 'CPF cadastrado de novo: contatos atualizados' }
const LEAD_STATUS: Record<string, string> = { new: 'Novo', contacted: 'Em contato', qualified: 'Qualificado', converted: 'Convertido', lost: 'Perdido' }
const DONE = ['paid', 'rejected', 'cancelled']

// Client 360. The page is the client file: whoever can edit sees the full registration form, locked until "Editar cadastro"
// (owner decision); below it, contacts, contracts, leads and timeline. Roles without clientes.edit see read-only blocks.
export default async function CustomerDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const { supabase, access } = await requireAppContext()
  const [{ data: customer }, { data: contacts }, { data: proposals }, { data: leads }, { data: timeline }, { data: address }, { data: documents }, { data: accountRows }, { data: registrationRows }, { data: agreementRows }] = await Promise.all([
    supabase.from('clients').select('id,full_name,cpf,phone,email,birth_date,original_source,created_at,updated_at,father_name,mother_name,rg_number,rg_issuer,rg_state,rg_issued_on,gender,marital_status,birthplace_city,birthplace_state,whatsapp').eq('id', id).is('deleted_at', null).maybeSingle(),
    supabase.from('client_contacts').select('id,kind,value,is_primary,source,first_seen_at,last_seen_at').eq('customer_id', id).order('is_primary', { ascending: false }).order('last_seen_at', { ascending: false }),
    supabase.from('proposals_v2').select('id,status,external_proposal_id,requested_amount,released_amount,installment_amount,term,created_at').eq('customer_id', id).order('created_at', { ascending: false }).limit(100),
    supabase.from('leads').select('id,status,channel,created_at').eq('customer_id', id).order('created_at', { ascending: false }).limit(20),
    supabase.from('customer_timeline_events').select('id,event_type,source,occurred_at').eq('customer_id', id).order('occurred_at', { ascending: false }).limit(20),
    supabase.from('customer_addresses').select('postal_code,street,number,complement,neighborhood,city,state').eq('customer_id', id).eq('is_primary', true).limit(1).maybeSingle(),
    supabase.from('customer_documents').select('id,status,created_at').eq('customer_id', id).order('created_at', { ascending: false }).limit(20),
    supabase.from('customer_bank_accounts').select('id,bank_code,bank_name,branch,account_number,account_digit,account_type,is_primary').eq('customer_id', id).order('is_primary', { ascending: false }).order('created_at'),
    supabase.from('client_registrations').select('id,agreement_id,agency_name,registration_number,status,margin_amount,margin_as_of,portal_login,has_portal_password,notes').eq('customer_id', id).order('status').order('created_at'),
    supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name'),
  ])
  if (!customer) notFound()
  const open = (proposals ?? []).filter(p => !DONE.includes(p.status))
  const accounts = (accountRows ?? []) as BankAccount[]
  const registrations = (registrationRows ?? []) as Registration[]
  const profile = customer as unknown as ProfileFields
  const missing = missingProfileFields(profile, { hasBankAccount: accounts.length > 0, hasRegistration: registrations.length > 0 })
  const canEdit = can(access, 'clientes.edit')

  return (
    <section>
      <Link href="/app/clientes" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Clientes</Link>
      <header className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-[26px] font-semibold tracking-tight text-ink">{customer.full_name}</h1>
          <p className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted">
            <span className="font-mono text-ink-soft">CPF {formatCpf(customer.cpf)}</span>
            <span>Cliente desde {day(customer.created_at)}</span>
            <span>Origem: {source(customer.original_source)}</span>
          </p>
          {missing.length > 0 && <p className="mt-2 text-xs text-ink-soft"><Badge tone="pending">Cadastro incompleto</Badge> <span className="ml-1">Falta: {missing.join(', ')}.</span></p>}
        </div>
        <span className="flex flex-wrap gap-2">
          <ButtonLink href={`/app/propostas/nova?cliente=${customer.id}`}><FilePlus2 size={16} aria-hidden />Nova proposta</ButtonLink>
        </span>
      </header>

      {canEdit && (
        <Card className="mb-4 p-5">
          <ClientForm key={customer.updated_at} mode="edit" action={updateCustomer} client={customer as unknown as ClientFormValues} canEdit canReveal
            agreements={agreementRows ?? []} accounts={accounts} registrations={registrations}
            address={address ? { zip: address.postal_code ?? '', street: address.street ?? '', number: address.number ?? '', complement: address.complement ?? '', district: address.neighborhood ?? '', city: address.city ?? '', state: address.state ?? '' } : undefined} />
        </Card>
      )}

      <div className="grid gap-4 lg:grid-cols-[1fr_1.4fr]">
        <div className="grid content-start gap-4">
          <Card>
            <CardHeader title="Contatos" />
            <ul className="px-2 pb-2 pt-2">
              {(contacts ?? []).length === 0 && <li className="px-3 pb-3 text-sm text-muted">Nenhum contato registrado.</li>}
              {(contacts ?? []).map(c => (
                <li key={c.id} className="flex items-center gap-3 border-t border-line px-3 py-2.5 first:border-t-0">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm text-ink">{c.kind === 'email' ? c.value : formatPhone(c.value)}{c.kind === 'whatsapp' && <span className="ml-1 text-xs text-muted">WhatsApp</span>}</span>
                    <span className="block text-xs text-muted">{source(c.source)} · visto {day(c.last_seen_at)}{c.first_seen_at !== c.last_seen_at ? ` (desde ${day(c.first_seen_at)})` : ''}</span>
                  </span>
                  {c.is_primary && <Badge tone="brand">Principal</Badge>}
                </li>
              ))}
            </ul>
          </Card>

          <Card>
            <CardHeader title="Linha do tempo" />
            <ul className="px-5 pb-5 pt-3 text-sm">
              {(timeline ?? []).length === 0 && <li className="text-muted">Sem eventos.</li>}
              {(timeline ?? []).map(e => (
                <li key={e.id} className="flex gap-3 border-l-2 border-line py-1.5 pl-3">
                  <span className="num w-20 shrink-0 text-xs text-muted">{day(e.occurred_at)}</span>
                  <span className="text-ink-soft">{EVENT[e.event_type] ?? e.event_type}<span className="text-muted"> · {source(e.source)}</span></span>
                </li>
              ))}
            </ul>
          </Card>
        </div>

        <div className="grid content-start gap-4">
          {!canEdit && (
            <>
              <PersonalData p={profile} />
              <Registrations registrations={registrations} agreements={agreementRows ?? []} canReveal={false} />
              <BankAccounts accounts={accounts} />
            </>
          )}
          <Card>
            <CardHeader title={<span className="flex items-center gap-2">Contratos e propostas <Badge tone="neutral">{proposals?.length ?? 0}</Badge>{open.length > 0 && <Badge tone="paid-out">{open.length} em andamento</Badge>}</span>} />
            <div className="overflow-x-auto px-2 pb-2 pt-2">
              {(proposals ?? []).length === 0 ? (
                <p className="px-3 pb-3 text-sm text-muted">Nenhum contrato com este cliente ainda.</p>
              ) : (
                <table className="w-full text-left text-sm">
                  <thead className="text-xs text-muted"><tr><th className="px-3 py-2 font-medium">Data</th><th className="px-3 py-2 font-medium">ADE</th><th className="px-3 py-2 font-medium">Situação</th><th className="px-3 py-2 text-right font-medium">Valor</th><th className="px-3 py-2 text-right font-medium">Parcela</th></tr></thead>
                  <tbody>
                    {(proposals ?? []).map(p => (
                      <tr key={p.id} className="border-t border-line hover:bg-surface-muted">
                        <td className="num px-3 py-2 text-muted"><Link href={`/app/propostas/${p.id}`} className="hover:text-brand">{day(p.created_at)}</Link></td>
                        <td className="px-3 py-2 font-mono text-[13px] text-ink-soft">{p.external_proposal_id ?? '—'}</td>
                        <td className="px-3 py-2"><Badge tone={p.status === 'paid' ? 'received' : DONE.includes(p.status) ? 'neutral' : 'paid-out'}>{proposalStatusLabel(p.status).label}</Badge></td>
                        <td className="num px-3 py-2 text-right text-ink">{brl(p.released_amount ?? p.requested_amount)}</td>
                        <td className="num px-3 py-2 text-right text-ink-soft">{p.installment_amount ? `${brl(p.installment_amount)}${p.term ? ` × ${p.term}` : ''}` : '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </Card>

          {(leads ?? []).length > 0 && (
            <Card>
              <CardHeader title="Leads" />
              <ul className="px-2 pb-2 pt-2">
                {(leads ?? []).map(l => (
                  <li key={l.id} className="flex items-center justify-between border-t border-line px-3 py-2.5 text-sm first:border-t-0">
                    <span className="text-ink-soft">{l.channel} · {day(l.created_at)}</span>
                    <Badge tone={l.status === 'converted' ? 'received' : l.status === 'lost' ? 'neutral' : 'paid-out'}>{LEAD_STATUS[l.status] ?? l.status}</Badge>
                  </li>
                ))}
              </ul>
            </Card>
          )}

          {!canEdit && (
            <Card>
              <CardHeader title="Endereço principal" />
              <p className="px-5 pb-4 pt-3 text-sm text-ink">{address ? [address.street, address.number, address.complement, address.neighborhood, address.city && `${address.city}${address.state ? `/${address.state}` : ''}`, address.postal_code].filter(Boolean).join(' · ') : <span className="text-muted">Nenhum endereço cadastrado.</span>}</p>
            </Card>
          )}

          <Card>
            <CardHeader title="Documentos" />
            <ul className="px-2 pb-2 pt-2 text-sm">
              {(documents ?? []).length === 0 && <li className="px-3 pb-3 text-muted">Nenhum documento.</li>}
              {(documents ?? []).map(d => (
                <li key={d.id} className="flex justify-between border-t border-line px-3 py-2.5 first:border-t-0"><span className="text-ink-soft">{d.status}</span><span className="num text-muted">{day(d.created_at)}</span></li>
              ))}
            </ul>
          </Card>
        </div>
      </div>
    </section>
  )
}
