import { Card, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { BEVICRED_ORGANIZATION_ID } from '@/lib/bevicred'
import { TestButton } from './TestButton'

// Bevicred connection (phase 1, 07/10/2026): only tests whether Bevicred accepts the partner code and API key kept in
// the server settings, from the server's address. Nothing is read or written yet.
export default async function BevicredPage() {
  const { membership, organization } = await requireAppContext()
  const allowed = membership.role === 'admin' && organization.id === BEVICRED_ORGANIZATION_ID
  return (
    <section>
      <PageHeader title="Bevicred" description="Conexão com o webservice da Bevicred." />
      {!allowed ? <Card role="alert" className="p-5 text-sm text-ink-soft">Somente o administrador da empresa acessa esta conexão.</Card> : (
        <Card>
          <CardHeader title="Testar conexão" />
          <div className="space-y-3 px-5 pb-5 pt-3 text-sm text-ink-soft">
            <p>Pede um acesso (token) à Bevicred usando o código de parceiro e a chave da API guardados nas configurações do servidor. Mostra só se conectou ou o erro; nunca mostra a chave nem o token.</p>
            <p>Nada é lido nem gravado nos contratos ou no financeiro.</p>
            <TestButton />
          </div>
        </Card>
      )}
    </section>
  )
}
