import Link from 'next/link'
import { ConfirmSubmit } from '@/components/ConfirmSubmit'
import { headers } from 'next/headers'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { siteOrigin } from '@/lib/site-origin'
import { newSignupLink, setSignupLinkActive } from '../actions'
import { CopyLink } from './CopyLink'

// Registration links (owner approval 05/11/2026): one per seller group. The administrator copies the link of the group
// (Corretor, Afiliado...) and sends it; what arrives waits for approval on the sellers list.
export default async function SignupLinksPage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return <section><PageHeader title="Links de cadastro" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const [{ data: groups }, { data: links }] = await Promise.all([
    supabase.from('commission_groups').select('id,name').eq('is_active', true).order('sort_order').order('name'),
    supabase.from('seller_signup_links').select('id,commission_group_id,token,is_active'),
  ])
  const byGroup = new Map((links ?? []).map(l => [l.commission_group_id, l]))
  const h = await headers()
  const origin = (await siteOrigin()) ?? `${h.get('x-forwarded-proto') ?? 'http'}://${h.get('x-forwarded-host') ?? h.get('host') ?? ''}`
  const btn = 'h-9 rounded-none border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted'

  return (
    <section>
      <Link href="/app/cadastros/vendedores" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Vendedores</Link>
      <PageHeader title="Links de cadastro" description="Mande o link do grupo. A pessoa preenche o cadastro sem login e ele chega na lista de vendedores para você aprovar." />
      <Card>
        <CardHeader title="Um link por grupo" />
        <ul className="mt-3">
          {!(groups ?? []).length && <li className="border-t border-line px-5 py-4 text-sm text-muted">Cadastre antes um grupo de vendedores.</li>}
          {(groups ?? []).map(g => {
            const l = byGroup.get(g.id)
            return (
              <li key={g.id} className="flex flex-wrap items-center gap-3 border-t border-line px-5 py-3">
                <span className="w-32 shrink-0 text-sm font-semibold text-ink">{g.name}</span>
                {!l ? (
                  <>
                    <span className="flex-1 text-sm text-muted">Sem link</span>
                    <form action={newSignupLink}><input type="hidden" name="group_id" value={g.id} /><SubmitButton className={btn} pendingText="...">Criar link</SubmitButton></form>
                  </>
                ) : (
                  <>
                    {l.is_active ? <CopyLink url={`${origin}/cadastro/${l.token}`} label={g.name} /> : <span className="flex-1 text-sm text-muted">Link desligado</span>}
                    <Badge tone={l.is_active ? 'received' : 'neutral'}>{l.is_active ? 'Ligado' : 'Desligado'}</Badge>
                    <form action={setSignupLinkActive}><input type="hidden" name="link_id" value={l.id} /><input type="hidden" name="active" value={String(!l.is_active)} />
                      <SubmitButton className={btn} pendingText="...">{l.is_active ? 'Desligar' : 'Ligar'}</SubmitButton></form>
                    <form action={newSignupLink}><input type="hidden" name="group_id" value={g.id} />
                      <ConfirmSubmit confirm={`Trocar o link do grupo ${g.name}? O link atual para de funcionar na hora: quem já recebeu não conseguirá mais enviar o cadastro.`} className={btn} pendingText="...">Trocar link</ConfirmSubmit></form>
                  </>
                )}
              </li>
            )
          })}
        </ul>
        <p className="border-t border-line px-5 py-3 text-xs text-muted">Quem tiver o link consegue enviar um cadastro. Se o link foi parar com quem não devia, use Trocar link: o antigo para de funcionar na hora.</p>
      </Card>
    </section>
  )
}
