import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { Card, PageHeader, Badge } from '@/components/ui'
import { createProvider, setActive, updateProvider } from '../actions'

const btn = 'inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost = 'h-9 rounded-[10px] border border-line bg-surface px-3 text-xs hover:bg-surface-muted'
const TYPES: Record<string,string> = { bank_direct:'Banco direto', master:'Master', promotora:'Promotora', correspondent:'Correspondente', partner:'Parceiro', other:'Outro' }

export default async function OriginsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p className="text-sm text-muted">Sem permissão.</p></section>
  const { data: rows } = await supabase.from('organization_providers').select('id,name,provider_type,is_active').order('name')
  const active = (rows ?? []).filter(r => r.is_active).length
  return <section>
    <Link href="/app/cadastros" className="text-sm text-brand hover:underline">← Cadastros</Link>
    <PageHeader title="Promotoras parceiras" description="Cadastre aqui somente a empresa externa usada quando uma tabela/produção não é própria da sua operação." />
    <p className="-mt-4 mb-4 text-xs text-muted">{active} ativas · {(rows ?? []).length} no total</p>

    {canEdit && <Card className="p-5"><form action={createProvider} className="grid gap-2 md:grid-cols-3">
      <input type="hidden" name="return_to" value="/app/comercial/origens" />
      <input required name="name" maxLength={120} placeholder="Nome da empresa de origem" className="field md:col-span-2" />
      <select name="provider_type" defaultValue="master" className="field">{Object.entries(TYPES).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</select>
      <p className="text-xs text-muted md:col-span-2">A classificação é apenas descritiva da empresa externa. Ela não define quem é correspondente de quem.</p>
      <SubmitButton className={`${btn} md:justify-self-end`}>Cadastrar empresa</SubmitButton>
    </form></Card>}

    <Card className="mt-4 p-5">
      {!rows?.length ? <p className="text-sm text-muted">Nenhuma empresa de origem cadastrada.</p> :
      <div className="space-y-2">{rows.map(row => <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-[10px] border border-line p-3">
        <div><strong className="text-ink">{row.name}</strong><span className="ml-2 text-xs text-muted">· {TYPES[row.provider_type] ?? row.provider_type}</span><Badge tone={row.is_active ? 'received' : 'neutral'} className="ml-2">{row.is_active ? 'Ativa' : 'Inativa'}</Badge></div>
        {canEdit && <div className="flex items-center gap-3">
          <details><summary className="cursor-pointer text-xs text-brand underline">Editar</summary><form action={updateProvider} className="mt-2 grid min-w-72 gap-2"><input type="hidden" name="return_to" value="/app/comercial/origens" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className="field" /><select name="provider_type" defaultValue={row.provider_type} className="field">{Object.entries(TYPES).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</select><p className="text-[11px] text-muted">Você pode corrigir a classificação depois, por exemplo de Correspondente para Promotora.</p><SubmitButton className={ghost}>Salvar alterações</SubmitButton></form></details>
          <form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/origens" /><input type="hidden" name="kind" value="provider" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form>
        </div>}
      </div>)}</div>}
    </Card>
  </section>
}
