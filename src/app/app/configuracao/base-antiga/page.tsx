import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { LegacyImportClient } from './LegacyImportClient'
import { saveLegacyCutoff } from './actions'
import { LEGACY_STATUS } from '@/lib/legacy/fields'

const day = (d: string | null) => (d ? new Date(`${d.slice(0, 10)}T12:00:00Z`).toLocaleDateString('pt-BR') : '—')

// F5.5: clients and contracts of the previous system, for consultation only (map section 16a).
export default async function LegacyBasePage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) {
    return <section><PageHeader title="Base antiga" /><Card className="p-5 text-sm text-ink-soft">Somente administrador e gerente importam a base antiga.</Card></section>
  }
  const [{ data: settings }, { data: batches }] = await Promise.all([
    supabase.from('organization_legacy_settings').select('cutoff_on').maybeSingle(),
    supabase.from('legacy_import_batches').select('id,source_system,file_name,status,rows_total,rows_with_issue,clients_created,clients_matched,contracts_created,created_at')
      .order('created_at', { ascending: false }).limit(50),
  ])
  const owner = membership.role === 'admin'

  return (
    <section>
      <PageHeader title="Base antiga" description="Clientes e contratos do sistema anterior, só para consulta: aparecem na ficha do cliente e na busca, nunca em dashboards, metas, comissão ou financeiro. Cliente que já existe (mesmo CPF) é reconhecido, nunca duplicado." />

      <Card>
        <CardHeader title="Data de corte" />
        <form action={saveLegacyCutoff} className="flex flex-wrap items-end gap-3 p-5 pt-3">
          <label className="text-[13px] font-medium text-ink-soft">Início do uso do Corban
            <input type="date" name="cutoff_on" required defaultValue={settings?.cutoff_on ?? ''} disabled={!owner} className="field mt-1.5 w-auto" />
          </label>
          {owner && <SubmitButton className="h-10 rounded-[10px] border border-line-strong bg-surface px-4 text-sm text-ink hover:bg-surface-muted" pendingText="Salvando...">Salvar data de corte</SubmitButton>}
          <p className="w-full text-xs text-muted">Contratos a partir desta data não entram como antigos: eles são da esteira.</p>
        </form>
      </Card>

      {settings?.cutoff_on && (
        <Card className="mt-4">
          <CardHeader title="Importar arquivo" />
          <div className="p-5 pt-3"><LegacyImportClient /></div>
        </Card>
      )}

      <Card className="mt-4 overflow-hidden">
        <CardHeader title="Importações" />
        {!(batches ?? []).length ? <p className="px-5 pb-5 text-sm text-muted">Nenhuma importação ainda.</p> : (
          <table className="w-full text-left text-sm">
            <thead className="bg-surface-muted text-xs text-muted"><tr><th className="px-4 py-2">Arquivo</th><th className="px-4 py-2">Origem</th><th className="px-4 py-2">Situação</th><th className="px-4 py-2 text-right">Linhas</th><th className="px-4 py-2 text-right">Clientes novos / já existentes</th><th className="px-4 py-2 text-right">Contratos</th><th className="px-4 py-2">Enviado em</th></tr></thead>
            <tbody>
              {(batches ?? []).map(b => (
                <tr key={b.id} className="border-t border-line">
                  <td className="px-4 py-2"><Link href={`/app/configuracao/base-antiga/${b.id}`} className="font-medium text-brand hover:underline">{b.file_name}</Link></td>
                  <td className="px-4 py-2">{b.source_system}</td>
                  <td className="px-4 py-2"><Badge tone={LEGACY_STATUS[b.status]?.tone ?? 'neutral'}>{LEGACY_STATUS[b.status]?.label ?? b.status}</Badge></td>
                  <td className="px-4 py-2 text-right">{b.rows_total}{b.rows_with_issue ? <span className="text-xs text-muted"> ({b.rows_with_issue} com problema)</span> : null}</td>
                  <td className="px-4 py-2 text-right">{b.status === 'draft' ? '—' : `${b.clients_created} / ${b.clients_matched}`}</td>
                  <td className="px-4 py-2 text-right">{b.status === 'draft' ? '—' : b.contracts_created}</td>
                  <td className="px-4 py-2">{day(b.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Card>
    </section>
  )
}
