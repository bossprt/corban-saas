import Link from 'next/link'
import { cookies } from 'next/headers'
import { Search } from 'lucide-react'

// "Nova pesquisa" (owner decision 26/09/2026): back to the tables search with the filters that were marked. The search
// form remembers its filters in a cookie of that screen (api/comercial/tabelas/pesquisar); without one it opens an
// empty search.
export async function NewSearchLink() {
  const q = (await cookies()).get('tabelas_busca')?.value ?? ''
  return (
    <Link href={q ? `/app/comercial/tabelas?${q}` : '/app/comercial/tabelas'}
      className="mb-3 inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted">
      <Search size={15} aria-hidden />Nova pesquisa
    </Link>
  )
}
