import Link from 'next/link'
import { Search, UserRoundPlus } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf, formatPhone } from '@/lib/cpf'
import { digitsOnly, searchTerm } from '@/lib/search'
import { createCustomer } from './actions'
import { ClientForm } from './ClientForm'

const SOURCE_LABEL: Record<string, string> = { manual: 'Cadastro manual', corban_os: 'Cadastro manual', api: 'API', legado: 'Legado' }
const sourceLabel = (s: string | null) => (s ? SOURCE_LABEL[s] ?? (s.startsWith('lead:') ? `Lead (${s.slice(5)})` : s) : '—')

export default async function CustomersPage({ searchParams }: { searchParams: Promise<{ q?: string; novo?: string }> }) {
  const { supabase, access } = await requireAppContext()
  const sp = await searchParams
  // The list filter goes in the URL, so it only searches name and phone; CPF search is in Ctrl+K (server action, never in a URL).
  const q = searchTerm(sp.q)
  let query = supabase.from('clients').select('id,full_name,cpf,phone,original_source,created_at').is('deleted_at', null).order('created_at', { ascending: false }).limit(100)
  if (q) {
    const d = digitsOnly(q)
    query = query.or(d.length >= 4 ? `full_name.ilike.%${q}%,phone.ilike.%${d}%` : `full_name.ilike.%${q}%`)
  }
  const { data: customers, error } = await query
  const canCreate = can(access, 'clientes.create')
  // The profile blocks need clientes.edit (the database checks it again); agreements feed the first registration.
  const canEdit = can(access, 'clientes.edit')
  const { data: agreements } = canCreate && canEdit && sp.novo
    ? await supabase.from('organization_agreements').select('id,name').eq('is_active', true).order('name')
    : { data: [] as { id: string; name: string }[] }

  return (
    <section>
      <PageHeader
        title="Clientes"
        description="Um cliente por CPF. Cadastrar um CPF que já existe completa o cadastro em vez de duplicar."
        actions={canCreate ? <Link href={sp.novo ? '/app/clientes' : '/app/clientes?novo=1'} className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-medium text-white hover:bg-brand-strong"><UserRoundPlus size={16} aria-hidden />{sp.novo ? 'Fechar cadastro' : 'Novo cliente'}</Link> : null}
      />

      {canCreate && sp.novo && (
        <Card className="mb-6 p-5">
          <h2 className="mb-4 text-base font-semibold text-ink">Novo cliente</h2>
          <ClientForm mode="create" action={createCustomer} agreements={agreements ?? []} canEdit={canEdit} />
        </Card>
      )}

      <form className="mb-4 flex gap-2" role="search">
        <label className="flex h-10 flex-1 items-center gap-2 rounded-[10px] border border-line bg-surface px-3">
          <Search size={16} className="text-muted" aria-hidden />
          <input name="q" defaultValue={q ?? ''} placeholder="Filtrar por nome ou telefone (CPF: use Ctrl+K)" className="h-full flex-1 bg-transparent text-sm outline-none placeholder:text-muted" aria-label="Filtrar clientes" />
        </label>
        <button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted">Filtrar</button>
      </form>

      {error ? (
        <Card className="p-5 text-sm text-[#991B1B]">Não foi possível carregar os clientes agora.</Card>
      ) : (
        <Card className="overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="bg-surface-muted text-xs font-semibold text-muted">
                <tr><th className="px-4 py-2.5">Cliente</th><th className="px-4 py-2.5">CPF</th><th className="px-4 py-2.5">Telefone</th><th className="px-4 py-2.5">Origem</th><th className="px-4 py-2.5 text-right">Desde</th></tr>
              </thead>
              <tbody>
                {(customers ?? []).map(c => (
                  <tr key={c.id} className="border-t border-line-strong/60 hover:bg-surface-muted">
                    <td className="px-4 py-2.5 font-medium"><Link href={`/app/clientes/${c.id}`} className="text-ink hover:text-brand">{c.full_name}</Link></td>
                    <td className="px-4 py-2.5 font-mono text-[13px] text-ink-soft">{formatCpf(c.cpf)}</td>
                    <td className="px-4 py-2.5 text-ink-soft">{formatPhone(c.phone)}</td>
                    <td className="px-4 py-2.5 text-ink-soft">{sourceLabel(c.original_source)}</td>
                    <td className="num px-4 py-2.5 text-right text-muted">{new Date(c.created_at).toLocaleDateString('pt-BR')}</td>
                  </tr>
                ))}
                {!customers?.length && (
                  <tr><td colSpan={5} className="px-4 py-10 text-center text-sm text-muted">{q ? 'Nenhum cliente encontrado com esse filtro.' : 'Nenhum cliente seu ainda. Converta um lead ou cadastre um cliente.'}</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </section>
  )
}
