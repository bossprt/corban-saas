import { requireAppContext } from '@/lib/appContext'

export default async function DocumentsPage() {
  const { supabase } = await requireAppContext()
  const [documentsResult, typesResult, customersResult] = await Promise.all([
    supabase.from('customer_documents')
      .select('id,customer_id,document_type_id,version,original_file_name,mime_type,file_size_bytes,status,issued_at,expires_at,created_at')
      .order('created_at', { ascending: false }).limit(200),
    supabase.from('document_types').select('id,name,code').eq('is_active', true),
    supabase.from('clients').select('id,full_name').is('deleted_at', null),
  ])

  const typeNames = new Map((typesResult.data ?? []).map(t => [t.id, t.name]))
  const customerNames = new Map((customersResult.data ?? []).map(c => [c.id, c.full_name]))

  return <section>
    <div className="mb-6">
      <h1 className="text-3xl font-semibold">Documentos</h1>
      <p className="mt-2 text-sm text-slate-400">Cofre documental privado e versionado do tenant.</p>
    </div>

    <div className="overflow-hidden rounded-2xl border border-slate-800 bg-slate-900">
      <div className="overflow-x-auto"><table className="w-full text-left text-sm">
        <thead className="border-b border-slate-800 text-slate-400"><tr><th className="p-4">Cliente</th><th className="p-4">Documento</th><th className="p-4">Arquivo</th><th className="p-4">Versão</th><th className="p-4">Status</th></tr></thead>
        <tbody>
          {documentsResult.data?.map(d => <tr key={d.id} className="border-b border-slate-800/60 last:border-0">
            <td className="p-4 font-medium">{customerNames.get(d.customer_id) ?? 'Cliente'}</td>
            <td className="p-4">{typeNames.get(d.document_type_id) ?? 'Documento'}</td>
            <td className="p-4 text-slate-400">{d.original_file_name}</td>
            <td className="p-4 text-slate-400">v{d.version}</td>
            <td className="p-4"><span className="rounded-full bg-slate-800 px-2.5 py-1 text-xs">{d.status}</span></td>
          </tr>)}
          {!documentsResult.data?.length && <tr><td colSpan={5} className="p-8 text-center text-slate-500">Nenhum documento armazenado. Upload permanecerá bloqueado até as políticas privadas de Storage serem aplicadas.</td></tr>}
        </tbody>
      </table></div>
    </div>
  </section>
}
