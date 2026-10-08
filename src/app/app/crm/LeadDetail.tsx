import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Calculator, CalendarClock, ExternalLink, FileText, MessageCircle, UserRound, X } from 'lucide-react'
import { Badge, Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf, formatPhone } from '@/lib/cpf'
import { CHANNEL_LABEL, MANUAL_STAGES, STAGE_LABEL, STAGE_TONE, isLeadStage, stageLabel, whatsappHref } from '@/lib/crm'
import { proposalStatusLabel } from '@/lib/operational'
import { memberEmails } from '@/lib/team.server'
import { ClientForm, type ClientFormValues } from '@/app/app/clientes/ClientForm'
import { updateCustomer } from '@/app/app/clientes/actions'
import type { BankAccount, Registration } from '@/app/app/clientes/[id]/ProfileSections'
import { SavedSimulations } from '@/app/app/simulacoes/SavedSimulations'
import { SimulatorPanel, type SimulatorSp } from '@/app/app/simulacoes/SimulatorPanel'
import { addLeadNote, assignLeads, claimLead, setLeadStage, setNextContact, startLeadSale } from './actions'

const label = 'text-[13px] font-medium text-ink-soft'
const primary = 'inline-flex h-10 items-center justify-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const secondary = 'inline-flex h-9 items-center justify-center rounded-[10px] border border-line bg-surface px-3 text-sm font-medium text-ink hover:bg-surface-muted'
const TZ = 'America/Sao_Paulo'
const dateTime = (iso: string) => new Date(iso).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short', timeZone: TZ })
// datetime-local value in Brasília time (the input has no time zone).
const localInput = (iso: string | null) => (iso ? new Date(new Date(iso).getTime() - 3 * 3600_000).toISOString().slice(0, 16) : '')
function isPast(iso: string) { return new Date(iso).getTime() < Date.now() }

const EVENT_TEXT: Record<string, string> = {
  created: 'Lead cadastrado', imported: 'Veio da planilha da campanha', status_changed: 'Etapa alterada', owner_changed: 'Vendedor definido',
  converted: 'Virou cliente', client_linked: 'Ligado à ficha do cliente', note: 'Anotação', next_contact: 'Retorno marcado',
  proposal_linked: 'Proposta criada', won: 'Contrato pago: venda ganha', reactivated: 'Lead reaberto',
}
const LOST_REASONS = ['Sem margem', 'Não atende / telefone errado', 'Sem interesse', 'Taxa ou valor não agradou', 'Fechou com outro correspondente', 'Restrição / não aprovado']
export const LEAD_TABS = ['resumo', 'simular', 'ficha', 'propostas'] as const
export type LeadTab = (typeof LEAD_TABS)[number]
const TAB_LABEL: Record<LeadTab, string> = { resumo: 'Resumo', simular: 'Simular', ficha: 'Ficha do cliente', propostas: 'Propostas' }
export const leadTab = (v: string | undefined): LeadTab => ((LEAD_TABS as readonly string[]).includes(v ?? '') ? v as LeadTab : 'resumo')

type Info = Record<string, string>

// One lead with four tabs (owner, 08/10/2026: everything without leaving Vendas). Used by the side panel over the board
// and by the lead page. href(tab) builds this view's address for a tab; it is also where every form returns ("back").
// keep: the query fields the simulator's GET form must carry to stay in this view; close: the panel's close link.
export async function LeadDetail({ id, tab, sp, href, keep, close }: {
  id: string; tab: LeadTab; sp: SimulatorSp; href: (tab: LeadTab) => string; keep: Record<string, string>; close?: string
}) {
  const ctx = await requireAppContext()
  const { supabase, user, access } = ctx
  const { data: lead } = await supabase.from('leads')
    .select('id,full_name,status,channel,campaign_id,campaign,phone,email,cpf,owner_user_id,customer_id,proposal_id,next_contact_at,lost_reason,metadata,created_at,stage_changed_at')
    .eq('id', id).maybeSingle()
  if (!lead) notFound()
  const supervisor = can(access, 'leads.approve')
  const [{ data: events }, { data: campaign }, { data: client }, { data: proposal }, { data: members }] = await Promise.all([
    supabase.from('lead_events').select('id,event_type,from_status,to_status,actor_user_id,detail,created_at').eq('lead_id', id).order('created_at', { ascending: false }).limit(100),
    lead.campaign_id ? supabase.from('sales_campaigns').select('id,name').eq('id', lead.campaign_id).maybeSingle() : Promise.resolve({ data: null }),
    lead.customer_id ? supabase.from('clients').select('id,full_name,cpf').eq('id', lead.customer_id).maybeSingle() : Promise.resolve({ data: null }),
    lead.proposal_id ? supabase.from('proposals_v2').select('id,status,external_proposal_id').eq('id', lead.proposal_id).maybeSingle() : Promise.resolve({ data: null }),
    supervisor ? supabase.from('organization_memberships').select('user_id').eq('status', 'active') : Promise.resolve({ data: [] as { user_id: string }[] }),
  ])
  const emails = await memberEmails([lead.owner_user_id, ...(events ?? []).map(e => e.actor_user_id), ...(members ?? []).map(m => m.user_id)].filter(Boolean) as string[])
  const who = (u: string | null) => (!u ? 'Sistema' : u === user.id ? 'Você' : emails.get(u) ?? 'Usuário')

  const stage = isLeadStage(lead.status) ? lead.status : 'new'
  const closed = stage === 'won' || stage === 'lost'
  const canWork = can(access, 'leads.edit') && !closed
  const meta = (lead.metadata ?? {}) as { info?: Info; phone2?: string }
  const info = Object.entries(meta.info ?? {})
  const wa = whatsappHref(lead.phone)
  const cpf = client?.cpf ?? lead.cpf
  const here = href(tab)
  const back = (to = here) => <input type="hidden" name="back" value={to} />

  // Without a client yet: the CPF turns the lead into a client (or links the existing one), then the tab opens.
  const needClient = (next: LeadTab, what: string) => canWork ? (
    <Card>
      <CardHeader title={`Para ${what}, informe o CPF`} />
      <form action={startLeadSale} className="grid gap-3 px-5 pb-5 pt-3 sm:max-w-md">
        <input type="hidden" name="lead_id" value={lead.id} />{back(href(next))}
        <label className={label}>CPF do cliente<input required name="cpf" inputMode="numeric" placeholder="000.000.000-00" defaultValue={lead.cpf ? formatCpf(lead.cpf) : ''} className="field mt-1.5" /></label>
        <SubmitButton pendingText="Salvando..." className={primary}><Calculator size={16} aria-hidden />Cadastrar cliente e continuar</SubmitButton>
        <span className="text-xs text-muted">Se o CPF já for cliente, o lead fica ligado à ficha existente; senão o cliente é cadastrado com os dados do lead.</span>
      </form>
    </Card>
  ) : <Card className="p-5"><p className="text-sm text-muted">Este lead ainda não é cliente.</p></Card>

  return (
    <div>
      <header className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="flex flex-wrap items-center gap-2 text-xl font-semibold tracking-tight text-ink">{lead.full_name}<Badge tone={STAGE_TONE[stage]}>{STAGE_LABEL[stage]}</Badge></h2>
          <p className="mt-0.5 text-sm text-muted">{[campaign?.name ?? lead.campaign, CHANNEL_LABEL[lead.channel] ?? lead.channel, `entrou em ${dateTime(lead.created_at)}`].filter(Boolean).join(' · ')}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {wa && <a href={wa} target="_blank" rel="noopener noreferrer" className={`${secondary} gap-1.5`}><MessageCircle size={15} aria-hidden />WhatsApp</a>}
          {proposal && <Link href={`/app/propostas/${proposal.id}`} className={`${secondary} gap-1.5`}><FileText size={15} aria-hidden />Proposta na esteira</Link>}
          {close && <Link href={close} aria-label="Fechar" className="inline-flex size-9 items-center justify-center rounded-[10px] border border-line bg-surface text-ink-soft hover:bg-surface-muted"><X size={16} aria-hidden /></Link>}
        </div>
      </header>

      <nav aria-label="Seções do lead" className="mb-4 flex gap-1 overflow-x-auto border-b border-line">
        {LEAD_TABS.map(t => (
          <Link key={t} href={href(t)} aria-current={t === tab ? 'page' : undefined}
            className={`-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium ${t === tab ? 'border-brand text-brand' : 'border-transparent text-ink-soft hover:text-ink'}`}>
            {TAB_LABEL[t]}
          </Link>
        ))}
      </nav>

      {lead.owner_user_id === null && !closed && (
        <div className="mb-4 flex flex-wrap items-center gap-3 rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-3 text-sm text-[#92400E]">
          Este lead ainda não tem vendedor.
          {can(access, 'leads.edit') && <form action={claimLead}><input type="hidden" name="lead_id" value={lead.id} />{back()}<SubmitButton pendingText="Assumindo..." className={secondary}>Assumir este lead</SubmitButton></form>}
        </div>
      )}

      {tab === 'simular' && (client
        ? <SimulatorPanel sp={sp} keep={{ ...keep, aba: 'simular' }} client={client} back={href('propostas')} />
        : needClient('simular', 'simular'))}

      {tab === 'ficha' && (client ? <ClientFile clientId={client.id} back={here} /> : needClient('ficha', 'abrir a ficha'))}

      {tab === 'propostas' && (client ? (
        <div className="grid gap-3">
          <p className="text-sm text-ink-soft">As simulações gravadas são as propostas negociadas com o cliente. Venda combinada? Clique em <strong>Venda fechada: enviar para a esteira</strong>: a proposta vai para a digitação com os dados da simulação e o lead passa para Proposta.</p>
          <SavedSimulations customerId={client.id} back={here} title="Propostas negociadas" sendLabel="Venda fechada: enviar para a esteira" />
          <Link href={href('simular')} className={`${secondary} w-fit gap-1.5`}><Calculator size={15} aria-hidden />Nova simulação</Link>
        </div>
      ) : needClient('propostas', 'gravar propostas'))}

      {tab === 'resumo' && (
        <div className="grid gap-4 lg:grid-cols-[1.25fr_1fr]">
          <div className="grid content-start gap-4">
            <Card>
              <CardHeader title="Dados" />
              <dl className="grid gap-x-6 gap-y-3 px-5 pb-5 pt-3 text-sm sm:grid-cols-2">
                <div><dt className="text-xs text-muted">CPF</dt><dd className="num text-ink">{cpf ? formatCpf(cpf) : '—'}</dd></div>
                <div><dt className="text-xs text-muted">Telefone</dt><dd className="num text-ink">{lead.phone ? formatPhone(lead.phone) : '—'}{meta.phone2 && <span className="block text-muted">{formatPhone(meta.phone2)}</span>}</dd></div>
                <div><dt className="text-xs text-muted">E-mail</dt><dd className="break-all text-ink">{lead.email ?? '—'}</dd></div>
                <div><dt className="text-xs text-muted">Vendedor</dt><dd className="text-ink">{lead.owner_user_id ? who(lead.owner_user_id) : 'Sem vendedor'}</dd></div>
                <div><dt className="text-xs text-muted">Próximo contato</dt><dd className={`text-ink ${lead.next_contact_at && isPast(lead.next_contact_at) && !closed ? 'font-semibold text-[#B91C1C]' : ''}`}>{lead.next_contact_at ? dateTime(lead.next_contact_at) : '—'}</dd></div>
                <div><dt className="text-xs text-muted">Cliente</dt><dd className="text-ink">{client ? <Link href={href('ficha')} className="inline-flex items-center gap-1 text-brand hover:underline"><UserRound size={13} aria-hidden />{client.full_name}</Link> : 'Ainda não é cliente'}</dd></div>
                {proposal && <div><dt className="text-xs text-muted">Proposta</dt><dd className="text-ink">{proposal.external_proposal_id ?? 'Sem ADE'} · {proposalStatusLabel(proposal.status).label}</dd></div>}
                {stage === 'lost' && <div className="sm:col-span-2"><dt className="text-xs text-muted">Motivo da perda</dt><dd className="text-ink">{lead.lost_reason}</dd></div>}
              </dl>
            </Card>

            {info.length > 0 && (
              <Card>
                <CardHeader title="Informações da planilha" />
                <dl className="grid gap-x-6 gap-y-2.5 px-5 pb-5 pt-3 text-sm sm:grid-cols-2">
                  {info.map(([k, v]) => <div key={k}><dt className="text-xs text-muted">{k}</dt><dd className="num text-ink">{v}</dd></div>)}
                </dl>
              </Card>
            )}

            <Card>
              <CardHeader title="Histórico" />
              {canWork && (
                <form action={addLeadNote} className="flex gap-2 border-b border-line px-5 pb-4 pt-3">
                  <input type="hidden" name="lead_id" value={lead.id} />{back()}
                  <input name="note" required maxLength={1000} placeholder="Anotar: o que o cliente disse, o que ficou combinado..." aria-label="Anotação" className="field flex-1" />
                  <SubmitButton pendingText="Salvando..." className={secondary}>Anotar</SubmitButton>
                </form>
              )}
              <ol className="px-5 py-3">
                {(events ?? []).map(e => {
                  const d = (e.detail ?? {}) as Record<string, unknown>
                  const extra = e.event_type === 'note' ? String(d.text ?? '')
                    : e.event_type === 'next_contact' ? (d.at ? dateTime(String(d.at)) : 'retorno removido')
                    : e.event_type === 'status_changed' || e.event_type === 'reactivated' ? `${stageLabel(e.from_status ?? '')} → ${stageLabel(e.to_status ?? '')}${d.lost_reason ? ` · ${String(d.lost_reason)}` : ''}${d.proposal_status ? ` (proposta ${d.proposal_status === 'cancelled' ? 'cancelada' : 'recusada'})` : ''}`
                    : e.event_type === 'owner_changed' ? who(String(d.owner_user_id ?? '') || null)
                    : ''
                  return (
                    <li key={e.id} className="border-t border-line py-2.5 text-sm first:border-t-0">
                      <span className="flex flex-wrap items-baseline justify-between gap-2">
                        <span className="font-medium text-ink">{EVENT_TEXT[e.event_type] ?? e.event_type}</span>
                        <span className="text-xs text-muted">{who(e.actor_user_id)} · {dateTime(e.created_at)}</span>
                      </span>
                      {extra && <span className={`block ${e.event_type === 'note' ? 'whitespace-pre-wrap text-ink-soft' : 'text-muted'}`}>{extra}</span>}
                    </li>
                  )
                })}
              </ol>
            </Card>
          </div>

          <div className="grid content-start gap-4">
            {canWork && (
              <Card>
                <CardHeader title="Próximo contato" />
                <form action={setNextContact} className="grid gap-3 px-5 pb-5 pt-3">
                  <input type="hidden" name="lead_id" value={lead.id} />{back()}
                  <label className={label}>Quando retornar<input type="datetime-local" name="next_contact_at" defaultValue={localInput(lead.next_contact_at)} className="field mt-1.5" /></label>
                  <label className={label}>Anotação (opcional)<input name="note" maxLength={1000} placeholder="Ex.: pediu para ligar depois do pagamento" className="field mt-1.5" /></label>
                  <SubmitButton pendingText="Salvando..." className={primary}><CalendarClock size={16} aria-hidden />Marcar retorno</SubmitButton>
                  <span className="text-xs text-muted">O retorno aparece na tela Hoje. Deixe a data em branco para tirar.</span>
                </form>
              </Card>
            )}

            {canWork && (
              <Card>
                <CardHeader title="Etapa" />
                <div className="grid gap-4 px-5 pb-5 pt-3">
                  {stage === 'proposal'
                    ? <p className="text-sm text-muted">Com proposta em andamento, a etapa segue a proposta: vira Ganho quando o contrato for pago e volta para Negociando se a proposta for recusada ou cancelada.</p>
                    : (
                      <div className="flex flex-wrap gap-2">
                        {MANUAL_STAGES.filter(s => s !== 'lost').map(s => (
                          <form key={s} action={setLeadStage}>
                            <input type="hidden" name="lead_id" value={lead.id} />{back()}
                            <button name="status" value={s} disabled={s === stage} className={`${secondary} disabled:border-brand disabled:bg-brand/10 disabled:text-brand`}>{STAGE_LABEL[s]}</button>
                          </form>
                        ))}
                      </div>
                    )}
                  <form action={setLeadStage} className="grid gap-2 border-t border-line pt-4">
                    <input type="hidden" name="lead_id" value={lead.id} />{back()}
                    <input type="hidden" name="status" value="lost" />
                    <label className={label}>Marcar como perdido
                      <input name="lost_reason" required maxLength={300} list="lost-reasons" placeholder="Motivo" className="field mt-1.5" />
                    </label>
                    <datalist id="lost-reasons">{LOST_REASONS.map(r => <option key={r} value={r} />)}</datalist>
                    <SubmitButton pendingText="Salvando..." className={`${secondary} text-[#B91C1C]`}>Marcar como perdido</SubmitButton>
                  </form>
                </div>
              </Card>
            )}

            {stage === 'lost' && supervisor && (
              <Card>
                <CardHeader title="Reabrir" />
                <form action={setLeadStage} className="flex items-center gap-3 px-5 pb-5 pt-3">
                  <input type="hidden" name="lead_id" value={lead.id} />{back()}
                  <input type="hidden" name="status" value="contacted" />
                  <SubmitButton pendingText="Reabrindo..." className={secondary}>Reabrir lead</SubmitButton>
                  <span className="text-xs text-muted">Volta para Em contato.</span>
                </form>
              </Card>
            )}

            {supervisor && !closed && (
              <Card>
                <CardHeader title="Vendedor" />
                <form action={assignLeads} className="grid gap-3 px-5 pb-5 pt-3">
                  <input type="hidden" name="lead_id" value={lead.id} />{back()}
                  <label className={label}>Passar para
                    <select name="owner_user_id" required defaultValue={lead.owner_user_id ?? ''} className="field mt-1.5">
                      <option value="" disabled>Escolha</option>
                      {(members ?? []).map(m => <option key={m.user_id} value={m.user_id}>{who(m.user_id)}</option>)}
                    </select>
                  </label>
                  <SubmitButton pendingText="Salvando..." className={secondary}>Trocar vendedor</SubmitButton>
                </form>
              </Card>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

// The client's registration form inside the lead (locked until "Editar cadastro"), saving back to this tab.
async function ClientFile({ clientId, back }: { clientId: string; back: string }) {
  const { supabase, access } = await requireAppContext()
  const [{ data: customer }, { data: address }, { data: accountRows }, { data: registrationRows }, { data: agreementRows }] = await Promise.all([
    supabase.from('clients').select('id,full_name,cpf,phone,email,birth_date,updated_at,father_name,mother_name,rg_number,rg_issuer,rg_state,rg_issued_on,gender,marital_status,birthplace_city,birthplace_state,whatsapp').eq('id', clientId).is('deleted_at', null).maybeSingle(),
    supabase.from('customer_addresses').select('postal_code,street,number,complement,neighborhood,city,state').eq('customer_id', clientId).eq('is_primary', true).limit(1).maybeSingle(),
    supabase.from('customer_bank_accounts').select('id,bank_code,bank_name,branch,account_number,account_digit,account_type,is_primary').eq('customer_id', clientId).order('is_primary', { ascending: false }).order('created_at'),
    supabase.from('client_registrations').select('id,agreement_id,agency_name,registration_number,status,margin_amount,margin_as_of,portal_login,has_portal_password,notes').eq('customer_id', clientId).order('status').order('created_at'),
    supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name'),
  ])
  if (!customer) return <Card className="p-5"><p className="text-sm text-muted">Ficha do cliente não encontrada.</p></Card>
  const canEdit = can(access, 'clientes.edit')
  return (
    <Card className="p-5">
      <div className="mb-3 flex justify-end"><Link href={`/app/clientes/${customer.id}`} className="inline-flex items-center gap-1 text-sm text-brand hover:underline"><ExternalLink size={14} aria-hidden />Ficha completa (documentos, contratos)</Link></div>
      <ClientForm key={customer.updated_at} mode="edit" action={updateCustomer} client={customer as unknown as ClientFormValues} canEdit={canEdit} canReveal back={back}
        agreements={agreementRows ?? []} accounts={(accountRows ?? []) as BankAccount[]} registrations={(registrationRows ?? []) as Registration[]}
        address={address ? { zip: address.postal_code ?? '', street: address.street ?? '', number: address.number ?? '', complement: address.complement ?? '', district: address.neighborhood ?? '', city: address.city ?? '', state: address.state ?? '' } : undefined} />
    </Card>
  )
}
