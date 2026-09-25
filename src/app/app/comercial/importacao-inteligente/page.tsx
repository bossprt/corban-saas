
import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SmartImportClient } from './SmartImportClient'

export default async function SmartImportPage(){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'manager'))return <section><p>Sem permissão.</p></section>
 const providers=await supabase.from('organization_providers').select('id,name,provider_type,is_active').eq('is_active',true).order('name')
 return <section>
  <Link href="/app/comercial/tabelas" className="text-sm text-slate-400 underline">← Voltar às Tabelas</Link>
  <div className="mt-3 flex flex-wrap items-end justify-between gap-3"><div><p className="text-sm text-emerald-400">Importação inteligente</p><h1 className="mt-1 text-3xl font-semibold">Atualizar tabelas e comissões em minutos</h1><p className="mt-2 max-w-4xl text-sm text-slate-400">Envie a planilha que o banco/master te paga. O Corban identifica tabelas, prazos, tipos, taxas, fatores e componentes. Ele só pergunta quando encontra algo que exige decisão.</p></div><a href="/api/comercial/modelo" className="rounded-lg border border-emerald-500/50 px-3 py-2 text-sm text-emerald-300">Baixar modelo XLSX do Corban</a></div>
  <div className="mt-6"><SmartImportClient providers={(providers.data??[]).map(p=>({id:p.id,name:p.name,provider_type:p.provider_type}))}/></div>
 </section>
}
