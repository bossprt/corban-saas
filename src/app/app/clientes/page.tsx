import Link from 'next/link'
import { Search, UserRoundPlus } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf, formatPhone } from '@/lib/cpf'
import { digitsOnly, searchTerm } from '@/lib/search'
import { foldText } from '@/lib/finance/search'
import { createCustomer } from './actions'
import { ClientForm } from './ClientForm'
import { CpfSearchForm } from '@/components/CpfSearchForm'
import { formatDateSP } from '@/lib/dates'

const SOURCE_LABEL: Record<string, string> = { manual: 'Cadastro manual', corban_os: 'Cadastro manual', api: 'API', legado: 'Legado' }
const sourceLabel = (s: string | null) => (s ? SOURCE_LABEL[s] ?? (s.startsWith('lead:') ? `Lead (${s.slice(5)})` : s.startsWith('legacy:') ? `Base antiga (${s.slice(7)})` : s) : '—')

export default async function CustomersPage({ searchParams }: { searchParams: Promise<{ q?: string; novo?: string }> }) {
  const { supabase, access } = await requireAppContext()
  const sp = await searchParams
  // Name and phone filter through the URL; a CPF typed in the same box is looked up by POST (CpfSearchForm) and opens the client.
  const q = searchTerm(sp.q)
  // Owner (08/11/2026): the tab opens with no list, only "Novo cliente" and the search; clients appear only for a search.
  let customers: { id: string; full_name: string; cpf: string | null; phone: string | null; original_source: string | null; created_at: string }[] | null = null
  let error: unknown = null
  if (q) {
    const d = digitsOnly(q)
    // The name is matched without accents or case against clients.search_name, folded by the database ("joao" finds "João").
    const name = `search_name.like.%${foldText(q)}%`
    const res = await supabase.from('clients').select('id,full_name,cpf,phone,original_source,created_at').is('deleted_at', null)
      .or(d.length >= 4 ? `${name},phone.ilike.%${d}%` : name).order('full_name').limit(100)
    customers = res.data
    error = res.error
  }
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
        description="Procure um cliente para abrir a ficha completa. Um cliente por CPF: cadastrar um CPF que já existe completa o cadastro."
        actions={canCreate ? <Link href={sp.novo ? '/app/clientes' : '/app/clientes?novo=1'} className="inline-flex h-10 items-center gap-2 rounded-[10px] bg-brand px-4 text-sm font-medium text-white hover:bg-brand-strong"><UserRoundPlus size={16} aria-hidden />{sp.novo ? 'Fechar cadastro' : 'Novo cliente'}</Link> : null}
      />

      {canCreate && sp.novo && (
        <Card className="mb-6 p-5">
          <h2 className="mb-4 text-base font-semibold text-ink">Novo cliente</h2>
          <ClientForm mode="create" action={createCustomer} agreements={agreements ?? []} canEdit={canEdit} />
        </Card>
      )}

      <CpfSearchForm action="/app/clientes" mode="client" className="mb-4 flex gap-2">
        <label className="flex h-10 flex-1 items-center gap-2 rounded-[10px] border border-line bg-surface px-3">
          <Search size={16} className="text-muted" aria-hidden />
          <input name="q" defaultValue={q ?? ''} placeholder="Nome, CPF ou telefone" className="h-full flex-1 bg-transparent text-sm outline-none placeholder:text-muted" aria-label="Filtrar clientes" />
        </label>
        <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Search size={15} aria-hidden />Procurar</button>
      </CpfSearchForm>

      {!q ? (
        <div className="px-4 py-12 text-center text-sm text-muted">
          <p className="mb-1 text-base font-semibold text-ink">Nenhuma lista aberta</p>
          <p>Digite o nome, CPF ou telefone.</p>
          <p>Com o CPF completo, a ficha do cliente abre direto.</p>
        </div>
      ) : error ? (
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
                    <td className="num px-4 py-2.5 text-right text-muted">{formatDateSP(c.created_at)}</td>
                  </tr>
                ))}
                {!customers?.length && (
                  <tr><td colSpan={5} className="px-4 py-10 text-center text-sm text-muted">
                    Nenhum cliente encontrado com essa busca.
                    {canCreate && <Link href="/app/clientes?novo=1" className="ml-3 inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-sm font-medium text-white hover:bg-brand-strong">Cadastrar novo cliente</Link>}
                  </td></tr>
                )}
              </tbody>
            </table>
          </div>
          {!!customers?.length && <p className="border-t border-line px-4 py-2 text-xs text-muted">{customers.length === 100 ? 'Mostrando os 100 primeiros. Digite mais do nome para achar o cliente.' : `${customers.length} ${customers.length === 1 ? 'cliente encontrado' : 'clientes encontrados'}. Clique para abrir a ficha.`}</p>}
        </Card>
      )}
    </section>
  )
}
