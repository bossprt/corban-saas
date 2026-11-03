import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { listBevicredCredentials } from '@/lib/bevicred.server'
import { CredentialForm } from './CredentialForm'
import { testBevicred } from './actions'

const when = (iso: string) => new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' })

// Bevicred credentials of the company (03/11/2026): the administrator registers one or more (partner code and API key),
// kept encrypted in Vault. The key is never shown again; the partner code only masked.
export default async function BevicredPage() {
  const { membership, organization } = await requireAppContext()
  if (membership.role !== 'admin') return (
    <section>
      <PageHeader title="Bevicred" />
      <Card role="alert" className="p-5 text-sm text-ink-soft">Somente o administrador da empresa acessa as credenciais da Bevicred.</Card>
    </section>
  )
  const credentials = await listBevicredCredentials(organization.id)
  return (
    <section className="space-y-4">
      <PageHeader title="Bevicred" description="Credenciais desta empresa no webservice da Bevicred. A chave fica guardada criptografada e nunca aparece de novo." />
      <Card>
        <CardHeader title="Credenciais" />
        {credentials.length === 0 ? <p className="px-5 pb-5 pt-3 text-sm text-ink-soft">Nenhuma credencial cadastrada.</p> : (
          <ul className="mt-3">
            {credentials.map(c => (
              <li key={c.id} className="border-t border-line px-5 py-3 text-sm">
                <div className="flex flex-wrap items-center gap-3">
                  <span className="min-w-28 font-semibold text-ink">{c.label}</span>
                  <span className="num min-w-28 text-ink-soft">{c.partner_hint}</span>
                  <span className="flex-1">
                    {c.last_test_at === null ? <Badge tone="pending">Não testada</Badge>
                      : <Badge tone={c.last_test_ok ? 'received' : 'diverged'}>{c.last_test_ok ? 'Conectado' : 'Falhou'} em {when(c.last_test_at)}</Badge>}
                    {c.last_test_ok === false && c.last_test_message && <span className="mt-1 block text-xs text-ink-soft">{c.last_test_message}</span>}
                  </span>
                  <form action={testBevicred}>
                    <input type="hidden" name="credential_id" value={c.id} />
                    <SubmitButton pendingText="Testando..." className="h-9 rounded-[10px] border border-line px-3 font-medium text-ink-soft hover:bg-surface-muted">Testar</SubmitButton>
                  </form>
                </div>
                <details className="mt-2">
                  <summary className="cursor-pointer text-[13px] font-medium text-brand hover:text-brand-strong">Trocar chave</summary>
                  <div className="pt-3"><CredentialForm credentialId={c.id} /></div>
                </details>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <Card>
        <CardHeader title="Adicionar credencial" />
        <div className="px-5 pb-5 pt-3">
          <CredentialForm />
          <p className="mt-3 text-xs text-muted">Ao salvar, o Corban testa a conexão. Nada é lido nem gravado nos contratos ou no financeiro.</p>
        </div>
      </Card>
    </section>
  )
}
