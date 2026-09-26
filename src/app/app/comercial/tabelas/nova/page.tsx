import Link from 'next/link'
import { ArrowLeft } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { createCommercialTable } from '../../actions'

const lbl = 'text-[13px] font-medium text-ink-soft'

// A new commission table by hand (most tables come from the import). It starts with an empty draft vigência.
export default async function NewTablePage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return <section><PageHeader title="Nova tabela" /><Card className="p-5 text-sm text-ink-soft">Seu papel não cria tabelas.</Card></section>
  const [banks, agreements, providers] = await Promise.all([
    supabase.from('organization_banks').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name'),
    supabase.from('organization_providers').select('id,name').eq('is_active', true).order('name'),
  ])
  return (
    <section>
      <Link href="/app/comercial/tabelas" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Tabelas</Link>
      <PageHeader title="Nova tabela" description="Para várias tabelas de uma vez, use Importar planilha." />
      <Card className="p-5">
        <form action={createCommercialTable} className="grid gap-3 md:grid-cols-2">
          <label className={lbl}>Banco<select required name="bank_id" defaultValue="" className="field mt-1.5"><option value="" disabled>Escolha</option>{(banks.data ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          <label className={lbl}>Convênio<select required name="agreement_id" defaultValue="" className="field mt-1.5"><option value="" disabled>Escolha</option>{(agreements.data ?? []).map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          <label className={lbl}>Origem da produção<select required name="production_origin" defaultValue="own" className="field mt-1.5"><option value="own">Produção própria</option><option value="third_party">Por promotora parceira</option></select></label>
          <label className={lbl}>Promotora parceira <span className="font-normal text-muted">se for o caso</span><select name="provider_id" defaultValue="" className="field mt-1.5"><option value="">—</option>{(providers.data ?? []).map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <label className={`${lbl} md:col-span-2`}>Nome da tabela<input required name="name" maxLength={120} className="field mt-1.5" /></label>
          <div className="md:col-span-2 flex justify-end"><SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong">Criar tabela</SubmitButton></div>
        </form>
      </Card>
    </section>
  )
}
