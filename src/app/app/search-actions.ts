'use server'

import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { digitsOnly, searchTerm } from '@/lib/search'

export type SearchHit = { kind: 'client' | 'proposal' | 'seller'; id: string; title: string; subtitle: string; href: string }

const LIMIT = 6

// Global search behind Ctrl+K. Runs as a server action (POST) so CPF and phone never travel in a URL or an access log.
// Every query goes through the tenant-scoped client, so RLS and the organization filter apply as on any other screen.
export async function searchAll(raw: string): Promise<SearchHit[]> {
  const { supabase, membership } = await requireAppContext()
  const q = searchTerm(raw)
  if (!q) return []
  const digits = digitsOnly(q)
  const onlyDigits = digits.length > 0 && digits.length === q.replace(/[\s.\-/]/g, '').length
  const hits: SearchHit[] = []

  let clients = supabase.from('clients').select('id,full_name,cpf,phone').is('deleted_at', null).limit(LIMIT)
  if (onlyDigits && digits.length === 11) clients = clients.eq('cpf', digits)
  else if (onlyDigits && digits.length >= 4) clients = clients.or(`cpf.like.${digits}%,phone.like.%${digits}%`)
  else clients = clients.ilike('full_name', `%${q}%`)
  const { data: clientRows } = await clients
  for (const c of clientRows ?? []) {
    hits.push({ kind: 'client', id: c.id, title: c.full_name, subtitle: [formatCpf(c.cpf), c.phone].filter(Boolean).join(' · '), href: `/app/clientes/${c.id}` })
  }

  // ADE / bank proposal number: prefix match on the external number.
  if (/^[\w.-]{3,40}$/.test(q)) {
    const { data: ids } = await supabase.from('proposal_external_identities').select('proposal_id,external_proposal_number,institution_key').ilike('external_proposal_number', `${q}%`).limit(LIMIT)
    for (const p of ids ?? []) {
      hits.push({ kind: 'proposal', id: p.proposal_id, title: `ADE ${p.external_proposal_number}`, subtitle: p.institution_key ?? 'Proposta', href: `/app/propostas/${p.proposal_id}` })
    }
    const { data: direct } = await supabase.from('proposals_v2').select('id,external_proposal_id,status').ilike('external_proposal_id', `${q}%`).limit(LIMIT)
    for (const p of direct ?? []) {
      if (!hits.some(h => h.kind === 'proposal' && h.id === p.id)) hits.push({ kind: 'proposal', id: p.id, title: `ADE ${p.external_proposal_id}`, subtitle: p.status, href: `/app/propostas/${p.id}` })
    }
  }

  if (atLeast(membership.role, 'supervisor') && !onlyDigits) {
    const { data: sellers } = await supabase.from('commercial_sellers').select('id,name,seller_category').ilike('name', `%${q}%`).limit(LIMIT)
    for (const s of sellers ?? []) hits.push({ kind: 'seller', id: s.id, title: s.name, subtitle: s.seller_category ?? 'Vendedor', href: '/app/cadastros/vendedores' })
  }

  return hits
}

function formatCpf(cpf: string | null) {
  const d = digitsOnly(cpf ?? '')
  return d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : null
}
