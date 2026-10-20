import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { BASE_STAGES, STAGE_LABEL } from '@/lib/crm'
import { saveLeadStage } from '../actions'

const label = 'text-[13px] font-medium text-ink-soft'
const btn = 'inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted'

type Stage = { id: string; name: string; base_status: string; sort_order: number; is_active: boolean }

// Company stages (supervisor): the open part of the Vendas board in the company's own words. Each stage belongs to one of
// the three base steps (Novo, Em contato, Negociando); Proposta, Ganho and Perdido stay fixed because they follow the proposal.
export default async function LeadStagesPage() {
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'leads.approve')) redirect('/app/crm')
  const { data } = await supabase.from('sales_lead_stages').select('id,name,base_status,sort_order,is_active').order('sort_order').order('name')
  const stages = (data ?? []) as Stage[]

  return (
    <section>
      <Link href="/app/crm" className="mb-3 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendas</Link>
      <PageHeader title="Etapas de vendas" description="Crie as colunas do quadro de Vendas com os nomes da sua empresa. Cada etapa fica dentro de um passo: Novo, Em contato ou Negociando. Um passo sem etapas continua com uma coluna só." />

      <div className="grid gap-4 lg:grid-cols-3">
        {BASE_STAGES.map(base => {
          const own = stages.filter(s => s.base_status === base)
          return (
            <Card key={base}>
              <CardHeader title={STAGE_LABEL[base]} />
              <ul className="px-5 pt-1">
                {own.length === 0 && <li className="py-2 text-sm text-muted">Sem etapas: o quadro mostra a coluna &quot;{STAGE_LABEL[base]}&quot;.</li>}
                {own.map(s => (
                  <li key={s.id} className="border-t border-line py-3 first:border-t-0">
                    <form action={saveLeadStage} className="grid gap-2">
                      <input type="hidden" name="stage_id" value={s.id} /><input type="hidden" name="base_status" value={s.base_status} />
                      <div className="grid grid-cols-[1fr_72px] gap-2">
                        <input name="name" required maxLength={40} defaultValue={s.name} aria-label="Nome" className="field" />
                        <input name="sort_order" type="number" min={0} max={999} defaultValue={s.sort_order} aria-label="Ordem" title="Ordem" className="field" />
                      </div>
                      <div className="flex flex-wrap items-center gap-2">
                        <SubmitButton pendingText="Salvando..." className={btn}>Salvar</SubmitButton>
                        {s.is_active
                          ? <button name="active" value="no" className={`${btn} text-ink-soft`}>Desligar</button>
                          : <button name="active" value="yes" className={btn}>Ligar de novo</button>}
                        {!s.is_active && <span className="text-xs text-muted">Desligada</span>}
                      </div>
                    </form>
                  </li>
                ))}
              </ul>
              <form action={saveLeadStage} className="grid gap-2 border-t border-line px-5 pb-5 pt-4">
                <input type="hidden" name="base_status" value={base} />
                <label className={label}>Nova etapa em {STAGE_LABEL[base]}
                  <div className="mt-1.5 grid grid-cols-[1fr_72px] gap-2">
                    <input name="name" required maxLength={40} placeholder="Ex.: Aguardando documento" className="field" />
                    <input name="sort_order" type="number" min={0} max={999} defaultValue={(own.at(-1)?.sort_order ?? 0) + 1} aria-label="Ordem" title="Ordem" className="field" />
                  </div>
                </label>
                <SubmitButton pendingText="Salvando..." className={`${btn} w-fit`}>Criar etapa</SubmitButton>
              </form>
            </Card>
          )
        })}
      </div>
      <p className="mt-4 text-xs text-muted">Ao desligar uma etapa, os leads dela vão para a primeira coluna do mesmo passo. Nada é apagado.</p>
    </section>
  )
}
