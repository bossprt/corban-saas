import Link from 'next/link'
import { ArrowLeft } from 'lucide-react'
import { SubmitButton } from '@/components/SubmitButton'
import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf } from '@/lib/cpf'
import { loadTableOptions } from '@/lib/proposals/table-options'
import { createDirectProposal } from './actions'

const label = 'text-[13px] font-medium text-ink-soft'

// New proposal without a simulation: pick the client, the bank table and the values; either it waits for
// digitization or it was already digitized (then the bank number/ADE is required).
export default async function NewProposalPage({ searchParams }: { searchParams: Promise<{ cliente?: string }> }) {
  const { supabase, access } = await requireAppContext()
  const sp = await searchParams
  if (!can(access, 'propostas.create')) {
    return <section><PageHeader title="Nova proposta" /><Card className="p-5 text-sm text-ink-soft">Seu papel não pode criar propostas.</Card></section>
  }

  const [{ data: clients }, { data: sellers }, options] = await Promise.all([
    supabase.from('clients').select('id,full_name,cpf').is('deleted_at', null).order('full_name').limit(300),
    supabase.from('commercial_sellers').select('id,name').eq('is_active', true).order('name'),
    loadTableOptions(supabase),
  ])

  return (
    <section>
      <Link href="/app/propostas" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Esteira</Link>
      <PageHeader title="Nova proposta" description="Simulou em outro lugar (portal do banco, planilha, outro CRM)? Registre aqui. Mesmo banco + ADE nunca duplica." />
      <Card className="max-w-3xl p-5">
        <form action={createDirectProposal} className="grid gap-4 sm:grid-cols-2">
          <label className={`${label} sm:col-span-2`}>Cliente
            <select name="customer_id" required defaultValue={sp.cliente ?? ''} className="field mt-1.5">
              <option value="" disabled>Escolha o cliente</option>
              {(clients ?? []).map(c => <option key={c.id} value={c.id}>{c.full_name} · {formatCpf(c.cpf)}</option>)}
            </select>
            <span className="mt-1 block text-xs text-muted">Cliente novo? Cadastre em <Link href="/app/clientes?novo=1" className="text-brand underline">Clientes</Link> primeiro.</span>
          </label>
          <label className={`${label} sm:col-span-2`}>Banco e tabela
            <select name="table_version_id" required defaultValue="" className="field mt-1.5">
              <option value="" disabled>Escolha a tabela</option>
              {options.map(o => <option key={o.id} value={o.id}>{o.label}</option>)}
            </select>
          </label>
          <label className={label}>Valor solicitado (R$)<input name="requested_amount" inputMode="decimal" placeholder="10.000,00" className="field mt-1.5" /></label>
          <label className={label}>Valor liberado (R$)<input name="released_amount" inputMode="decimal" placeholder="9.500,00" className="field mt-1.5" /></label>
          <label className={label}>Parcela (R$)<input name="installment_amount" inputMode="decimal" placeholder="250,00" className="field mt-1.5" /></label>
          <label className={label}>Prazo (meses)<input name="term" inputMode="numeric" placeholder="84" className="field mt-1.5" /></label>
          <label className={label}>Vendedor
            <select name="seller_id" defaultValue="" className="field mt-1.5">
              <option value="">Sem vendedor atribuído</option>
              {(sellers ?? []).map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </label>
          <fieldset className="sm:col-span-2">
            <legend className={label}>Situação</legend>
            <div className="mt-1.5 flex flex-wrap gap-4 text-sm text-ink">
              <label className="flex items-center gap-2"><input type="radio" name="stage" value="digitization_queue" defaultChecked className="accent-[var(--brand)]" />Aguardando digitação</label>
              <label className="flex items-center gap-2"><input type="radio" name="stage" value="submitted" className="accent-[var(--brand)]" />Já digitada no banco</label>
            </div>
          </fieldset>
          <label className={label}>Número da proposta no banco (ADE)<input name="ade" maxLength={60} placeholder="Obrigatório se já digitada" className="field mt-1.5 font-mono" /></label>
          <div className="flex items-end justify-end sm:col-span-2">
            <SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Salvando...">Registrar proposta</SubmitButton>
          </div>
        </form>
      </Card>
    </section>
  )
}
