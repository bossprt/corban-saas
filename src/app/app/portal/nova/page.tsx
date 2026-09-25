import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { SubmitButton } from '@/components/SubmitButton'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { isPortalUser } from '@/lib/portal'
import { loadTableOptions } from '@/lib/proposals/table-options'
import { submitPortalProposal } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'

// Broker sends a client and a proposal. It waits for the company to validate before entering the pipeline.
export default async function PortalNewProposalPage() {
  const { supabase, access, modules } = await requireAppContext()
  if (!isPortalUser(access?.roleKey, modules)) redirect('/app/propostas/nova')
  const options = await loadTableOptions(supabase)

  return (
    <section>
      <Link href="/app/portal" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Minhas propostas</Link>
      <PageHeader title="Nova proposta" description="A empresa confere e valida antes de a proposta entrar na esteira. Depois de enviar, você pode anexar os documentos." />
      <Card className="max-w-2xl p-5">
        <form action={submitPortalProposal} className="grid gap-4 sm:grid-cols-2">
          <fieldset className="grid gap-4 sm:col-span-2 sm:grid-cols-2">
            <legend className="mb-1 text-sm font-semibold text-ink">Cliente</legend>
            <label className={`${label} sm:col-span-2`}>Nome completo<input name="full_name" required minLength={3} maxLength={160} autoComplete="off" className="field mt-1.5" /></label>
            <label className={label}>CPF<input name="cpf" required inputMode="numeric" autoComplete="off" placeholder="000.000.000-00" className="field mt-1.5 font-mono" /></label>
            <label className={label}>Telefone<input name="phone" inputMode="tel" autoComplete="off" placeholder="(68) 99999-0000" className="field mt-1.5" /></label>
            <label className={`${label} sm:col-span-2`}>E-mail <span className="font-normal text-muted">opcional</span><input name="email" type="email" autoComplete="off" className="field mt-1.5" /></label>
          </fieldset>
          <fieldset className="grid gap-4 sm:col-span-2 sm:grid-cols-2">
            <legend className="mb-1 text-sm font-semibold text-ink">Proposta</legend>
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
            <label className={`${label} sm:col-span-2`}>Número da proposta no banco (ADE) <span className="font-normal text-muted">se já digitou</span><input name="ade" maxLength={60} className="field mt-1.5 font-mono" /></label>
          </fieldset>
          <div className="flex justify-end sm:col-span-2">
            <SubmitButton className="h-11 w-full rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong sm:w-auto" pendingText="Enviando...">Enviar para validação</SubmitButton>
          </div>
        </form>
      </Card>
    </section>
  )
}
