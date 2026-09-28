import { Badge, Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { uploadCustomerDocument } from './actions'
import { SubmitButton } from '@/components/SubmitButton'
import { ClientPicker } from '@/components/ClientPicker'

const DOC_STATUS: Record<string, string> = { active: 'Ativo', archived: 'Arquivado', expired: 'Vencido', rejected: 'Recusado' }
const DOC_TONE: Record<string, 'received' | 'neutral' | 'diverged' | 'reversed'> = { active: 'received', archived: 'neutral', expired: 'diverged', rejected: 'reversed' }

export default async function DocumentsPage() {
  const { supabase } = await requireAppContext()
  const [documentsResult, typesResult] = await Promise.all([
    supabase.from('customer_documents')
      .select('id,customer_id,document_type_id,version,original_file_name,mime_type,file_size_bytes,status,issued_at,expires_at,created_at')
      .order('created_at', { ascending: false }).limit(200),
    supabase.from('document_types').select('id,name,code').eq('is_active', true).order('name'),
  ])

  const typeNames = new Map((typesResult.data ?? []).map(t => [t.id, t.name]))
  // Names only of the clients that have documents listed here (never the whole client base).
  const ids = [...new Set((documentsResult.data ?? []).map(d => d.customer_id))]
  const { data: customers } = ids.length ? await supabase.from('clients').select('id,full_name').in('id', ids) : { data: [] as { id: string; full_name: string }[] }
  const customerNames = new Map((customers ?? []).map(c => [c.id, c.full_name]))

  return <section>
    <PageHeader title="Documentos" description="Documentos dos clientes: arquivo privado, cada envio vira uma nova versão, nada é sobrescrito." />

    <form action={uploadCustomerDocument} className="mb-6 grid gap-3 md:grid-cols-4">
      <Card className="col-span-full grid gap-3 p-5 md:grid-cols-4">
        <div className="md:col-span-4"><ClientPicker name="customer_id" /></div>
        <select required name="document_type_id" defaultValue="" className="field">
          <option value="" disabled>Tipo de documento</option>
          {typesResult.data?.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
        <input required type="file" name="file" accept=".pdf,image/jpeg,image/png,image/webp" className="field"/>
        <SubmitButton className="inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Enviando...">Enviar documento</SubmitButton>
        <p className="text-xs text-muted md:col-span-4">Arquivo privado · PDF, JPG, PNG ou WebP · máximo 4 MB · o tipo é conferido pelo conteúdo do arquivo · nada é sobrescrito (um novo envio vira uma nova versão).</p>
      </Card>
    </form>

    <Card className="overflow-hidden">
      <div className="overflow-x-auto"><table className="w-full text-left text-sm">
        <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-4 py-2.5">Cliente</th><th className="px-4 py-2.5">Documento</th><th className="px-4 py-2.5">Arquivo</th><th className="px-4 py-2.5">Versão</th><th className="px-4 py-2.5">Status</th></tr></thead>
        <tbody>
          {documentsResult.data?.map(d => <tr key={d.id} className="border-t border-line-strong/60 hover:bg-surface-muted">
            <td className="px-4 py-2.5 font-medium text-ink">{customerNames.get(d.customer_id) ?? 'Cliente'}</td>
            <td className="px-4 py-2.5 text-ink-soft">{typeNames.get(d.document_type_id) ?? 'Documento'}</td>
            <td className="px-4 py-2.5 text-ink-soft">{d.original_file_name}</td>
            <td className="px-4 py-2.5 text-ink-soft">v{d.version}</td>
            <td className="px-4 py-2.5"><Badge tone={DOC_TONE[d.status] ?? 'neutral'}>{DOC_STATUS[d.status] ?? d.status}</Badge></td>
          </tr>)}
          {!documentsResult.data?.length && <tr><td colSpan={5} className="px-4 py-10 text-center text-sm text-muted">Nenhum documento ainda. Escolha o cliente, o tipo e o arquivo acima. Depois, na proposta, anexe o documento ao item do checklist.</td></tr>}
        </tbody>
      </table></div>
    </Card>
  </section>
}
