import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { canManageTeam } from '@/lib/rbac'
import { saveStage } from './actions'

const STATE_LABEL: Record<string, string> = {
  digitization_queue: 'Aguardando digitação', digitizing: 'Em digitação', submitted: 'Em análise', pending_external: 'Pendência',
  approved: 'Aprovada', paid: 'Paga', rejected: 'Recusada', cancelled: 'Cancelada',
}

// Pipeline stages of the company: the name, order and time limit are the owner's; the underlying state is fixed
// because payment, commission and reports depend on it.
export default async function StagesPage() {
  const { supabase, membership } = await requireAppContext()
  if (!canManageTeam(membership.role)) {
    return <section><PageHeader title="Etapas da esteira" /><Card className="p-5 text-sm text-ink-soft">Somente administrador e gerente editam as etapas.</Card></section>
  }
  const { data: stages } = await supabase.from('operational_stages').select('id,code,name,canonical_state,sort_order,sla_minutes,is_active').order('sort_order')

  return (
    <section>
      <PageHeader title="Etapas da esteira" description="Renomeie, reordene, defina o prazo de cada etapa ou desligue as que não usa. O tipo da etapa não muda: pagamento, comissão e relatórios dependem dele." />
      <Card className="overflow-hidden">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-4 py-2.5"><div className="grid grid-cols-[1.6fr_1fr_80px_120px_70px_auto] gap-3"><span>Nome na esteira</span><span>Tipo</span><span>Ordem</span><span>Prazo (horas)</span><span>Ativa</span><span className="sr-only">Salvar</span></div></th></tr></thead>
          <tbody>
            {(stages ?? []).map(s => (
              <tr key={s.id} className="border-t border-line">
                <td className="px-4 py-2">
                  <form action={saveStage} className="grid grid-cols-[1.6fr_1fr_80px_120px_70px_auto] items-center gap-3">
                    <input type="hidden" name="stage_id" value={s.id} />
                    <input name="name" required minLength={2} maxLength={60} defaultValue={s.name} aria-label={`Nome da etapa ${s.name}`} className="field h-9 py-1" />
                    <span className="text-ink-soft">{STATE_LABEL[s.canonical_state] ?? s.canonical_state}</span>
                    <input name="sort_order" type="number" min={0} max={10000} defaultValue={s.sort_order} aria-label="Ordem" className="field h-9 py-1" />
                    <input name="sla_hours" type="number" min={0} max={8760} defaultValue={s.sla_minutes === null ? '' : Math.round(s.sla_minutes / 60)} placeholder="sem prazo" aria-label="Prazo em horas" className="field h-9 py-1" />
                    <input name="is_active" type="checkbox" value="true" defaultChecked={s.is_active} aria-label="Etapa ativa" className="size-4 accent-[var(--brand)]" />
                    <button className="h-9 rounded-lg border border-line px-3 text-xs hover:bg-surface-muted">Salvar</button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </section>
  )
}
