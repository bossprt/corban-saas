import { redirect } from 'next/navigation'
import { Card } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { signOut } from '@/app/app/actions'
import { acceptTerms } from './actions'

type Status = { required: boolean; accepted?: boolean; version_id?: string; version?: string; title?: string; body?: string; can_accept?: boolean }
const ERRORS: Record<string, string> = {
  marque: 'Marque que leu e aceita os termos para continuar.',
  versao: 'Os termos foram atualizados enquanto você lia. Leia a versão abaixo e aceite de novo.',
  falhou: 'Não foi possível registrar o aceite. Tente de novo.',
}

// Terms of use of the company (08/10/2026): while the version in force is not accepted, every screen comes here. The
// administrator reads and accepts on behalf of the company; the other users wait for it.
export default async function TermsPage({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const { supabase, organization } = await requireAppContext({ allowPendingTerms: true })
  const { data } = await supabase.rpc('terms_status', { p_org: organization.id })
  const s = (data ?? { required: false }) as Status
  if (!s.required || s.accepted) redirect('/app')
  const error = ERRORS[(await searchParams).erro ?? '']

  return (
    <main className="min-h-screen bg-canvas px-4 py-8">
      <Card className="mx-auto max-w-3xl p-6 sm:p-8">
        <p className="text-xs font-semibold uppercase tracking-[.2em] text-brand">{organization.name}</p>
        <h1 className="mt-1 text-2xl font-semibold text-ink">{s.title}</h1>
        <p className="mt-1 text-sm text-muted">Versão {s.version}. Para usar o Corban, a empresa precisa aceitar estes termos.</p>
        <div className="mt-5 max-h-[55vh] overflow-y-auto whitespace-pre-wrap rounded-[12px] border border-line bg-surface-muted px-4 py-3 text-sm leading-relaxed text-ink-soft">{s.body}</div>
        {error && <p role="alert" className="mt-4 rounded-lg bg-[#FDE2E1] px-3 py-2 text-sm text-[#991B1B]">{error}</p>}
        {s.can_accept ? (
          <form action={acceptTerms} className="mt-5 grid gap-3">
            <input type="hidden" name="version_id" value={s.version_id} />
            <label className="flex items-start gap-2 text-sm text-ink">
              <input type="checkbox" name="agree" required className="mt-0.5 accent-[var(--brand)]" />
              <span>Li e aceito estes termos em nome da empresa <strong>{organization.name}</strong>, e declaro ter poderes para isso.</span>
            </label>
            <p className="text-xs text-muted">O aceite fica registrado com seu usuário, data e hora, endereço de rede e navegador.</p>
            <div className="flex flex-wrap gap-3">
              <SubmitButton pendingText="Registrando..." className="h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Aceitar e entrar</SubmitButton>
            </div>
          </form>
        ) : (
          <p className="mt-5 rounded-lg bg-surface-muted px-3 py-2 text-sm text-ink-soft">O administrador da empresa precisa ler e aceitar estes termos antes que a equipe use o Corban. Assim que ele aceitar, seu acesso abre normalmente.</p>
        )}
        <form action={signOut} className="mt-4"><button className="text-sm text-muted underline hover:text-ink">Sair</button></form>
      </Card>
    </main>
  )
}
