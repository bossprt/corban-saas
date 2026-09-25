import { Badge, Card, CardBody, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { revokeApiKey } from './actions'
import { CreateKeyForm } from './CreateKeyForm'

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR') : '—')
const code = 'font-mono text-[13px]'

export default async function ApiSettingsPage() {
  const { supabase, membership, modules } = await requireAppContext()
  if (membership.role !== 'admin') {
    return <section><PageHeader title="API" /><Card className="p-5 text-sm text-ink-soft">Somente o administrador gerencia as chaves da API.</Card></section>
  }
  const { data: keys } = await supabase.from('api_keys').select('id,name,prefix,scopes,created_at,last_used_at,revoked_at').order('created_at', { ascending: false })
  const apiOn = modules.has('api')

  return (
    <section>
      <PageHeader title="API" description="Chaves para outros sistemas enviarem leads à sua empresa (por exemplo, o DeskcommCRM). Cada chave vale só para esta empresa." />
      {!apiOn && <p className="mb-4 rounded-lg bg-[#FEF3C7] px-4 py-3 text-sm text-[#92400E]">O módulo API está desligado no seu plano. As chaves existem, mas as chamadas são recusadas.</p>}

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader title="Nova chave" />
          <CardBody><CreateKeyForm /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Como usar" />
          <CardBody className="space-y-2 text-sm text-ink-soft">
            <p>Envie <code className={code}>POST /api/v1/leads</code> com o cabeçalho <code className={code}>Authorization: Bearer ck_live_…</code> e um JSON com <code className={code}>full_name</code> e <code className={code}>phone</code> ou <code className={code}>email</code>.</p>
            <p>Repetir a mesma <code className={code}>external_ref</code> devolve o mesmo lead. Um lead aberto com o mesmo telefone também não é duplicado.</p>
            <p>Descrição completa: <a className="text-brand underline" href="/api/v1/openapi.json">/api/v1/openapi.json</a></p>
          </CardBody>
        </Card>
      </div>

      <Card className="mt-4 overflow-hidden">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-muted text-xs font-semibold text-muted">
            <tr><th className="px-4 py-2.5">Nome</th><th className="px-4 py-2.5">Chave</th><th className="px-4 py-2.5">Criada</th><th className="px-4 py-2.5">Último uso</th><th className="px-4 py-2.5">Situação</th><th className="px-4 py-2.5"><span className="sr-only">Ações</span></th></tr>
          </thead>
          <tbody>
            {(keys ?? []).map(k => (
              <tr key={k.id} className="border-t border-line">
                <td className="px-4 py-2.5 font-medium text-ink">{k.name}</td>
                <td className="px-4 py-2.5 font-mono text-[13px] text-ink-soft">{k.prefix}…</td>
                <td className="num px-4 py-2.5 text-muted">{when(k.created_at)}</td>
                <td className="num px-4 py-2.5 text-muted">{when(k.last_used_at)}</td>
                <td className="px-4 py-2.5">{k.revoked_at ? <Badge tone="neutral">Revogada</Badge> : <Badge tone="received">Ativa</Badge>}</td>
                <td className="px-4 py-2.5 text-right">
                  {!k.revoked_at && (
                    <form action={revokeApiKey}>
                      <input type="hidden" name="key_id" value={k.id} />
                      <button className="text-sm text-[#991B1B] hover:underline">Revogar</button>
                    </form>
                  )}
                </td>
              </tr>
            ))}
            {!keys?.length && <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-muted">Nenhuma chave criada.</td></tr>}
          </tbody>
        </table>
      </Card>
    </section>
  )
}
