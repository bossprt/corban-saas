import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { formatBRL } from '@/lib/finance/ledger'
import { add, fromDecimalString, toDecimalString } from '@/lib/commission/money'

const STATUS:Record<string,string>={
  calculated:'Calculada',
  unavailable:'Não calculada',
}
const REASON:Record<string,string>={
  simulation_not_available:'Simulação indisponível para cálculo.',
  condition_not_snapshotted:'A condição comercial não foi congelada na simulação.',
  calculation_base_not_available:'Base de cálculo indisponível.',
  seller_commission_share_not_resolved:'A regra de repasse do Grupo de Comissão não pôde ser determinada com segurança.',
  seller_commission_not_available:'Comissão individual indisponível.',
}

export default async function CommissionsPage(){
  const {supabase,membership}=await requireAppContext()

  const {data:snapshots,error}=await supabase
    .from('proposal_seller_commission_snapshots')
    .select('id,proposal_id,seller_id,calculation_status,source_kind,calculation_base,effective_pct,amount,currency,reason,frozen_at')
    .order('frozen_at',{ascending:false})
    .limit(200)

  const sellerIds=[...new Set((snapshots??[]).map(s=>s.seller_id))]
  const sellers=sellerIds.length
    ? await supabase.from('commercial_sellers').select('id,name,user_id').in('id',sellerIds)
    : {data:[] as {id:string;name:string;user_id:string|null}[],error:null}

  const sellerNames=new Map((sellers.data??[]).map(s=>[s.id,s.name]))
  const zero=fromDecimalString('0')
  const total=toDecimalString(
    (snapshots??[]).reduce((sum,s)=>
      s.calculation_status==='calculated'&&s.amount!=null
        ? add(sum,fromDecimalString(String(s.amount)))
        : sum
    ,zero),
    2
  )

  const scopeText=membership.role==='agent'
    ? 'Você vê somente a sua comissão vinculada ao seu login.'
    : membership.role==='supervisor'
      ? 'Você vê somente a comissão dos vendedores que estão sob sua supervisão.'
      : 'Você vê a comissão de todos os vendedores da organização.'

  return <section>
    <h1 className="text-3xl font-semibold">Comissões</h1>
    <p className="mt-2 text-sm text-slate-400">{scopeText}</p>
    <p className="mt-1 text-xs text-slate-500">Esta área mostra a comissão individual congelada do vendedor. Ela é separada do Financeiro e da receita da empresa.</p>

    <div className="mt-6 grid gap-4 md:grid-cols-2">
      <div className="rounded-xl border border-slate-800 bg-slate-900 p-5">
        <div className="text-sm text-slate-400">Comissão calculada visível</div>
        <div className="mt-2 text-2xl font-semibold">{formatBRL(total)}</div>
      </div>
      <div className="rounded-xl border border-slate-800 bg-slate-900 p-5">
        <div className="text-sm text-slate-400">Registros visíveis</div>
        <div className="mt-2 text-2xl font-semibold">{snapshots?.length??0}</div>
      </div>
    </div>

    {error
      ? <p role="alert" className="mt-5 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-amber-200">Não foi possível consultar suas comissões.</p>
      : !(snapshots??[]).length
        ? <div className="mt-5 rounded-xl border border-slate-800 bg-slate-900 p-5 text-sm text-slate-400">
            Nenhuma comissão congelada está disponível para o seu escopo. O sistema não estima valores quando a regra de repasse não está comprovada.
          </div>
        : <div className="mt-5 overflow-x-auto rounded-xl border border-slate-800">
            <table className="min-w-full text-left text-sm">
              <thead className="bg-slate-900 text-slate-400">
                <tr>
                  <th className="p-3">Vendedor</th>
                  <th className="p-3">Proposta</th>
                  <th className="p-3">Base</th>
                  <th className="p-3">%</th>
                  <th className="p-3">Comissão</th>
                  <th className="p-3">Status</th>
                  <th className="p-3">Congelada em</th>
                </tr>
              </thead>
              <tbody>{(snapshots??[]).map(s=><tr key={s.id} className="border-t border-slate-800">
                <td className="p-3">{sellerNames.get(s.seller_id)??'Vendedor'}</td>
                <td className="p-3"><Link href={'/app/propostas/'+s.proposal_id} className="underline">{s.proposal_id.slice(0,8)}…</Link></td>
                <td className="p-3">{s.calculation_base==null?'—':formatBRL(String(s.calculation_base))}</td>
                <td className="p-3">{s.effective_pct==null?'—':String(s.effective_pct)+'%'}</td>
                <td className="p-3 font-medium">{s.amount==null?'—':formatBRL(String(s.amount))}</td>
                <td className="p-3">
                  <span className={s.calculation_status==='calculated'?'text-emerald-300':'text-amber-200'}>
                    {STATUS[s.calculation_status]??s.calculation_status}
                  </span>
                  {s.reason&&<span className="mt-1 block max-w-md text-xs text-slate-500">{REASON[s.reason]??'Cálculo indisponível sem inferência.'}</span>}
                </td>
                <td className="p-3 text-slate-400">{new Date(s.frozen_at).toLocaleString('pt-BR')}</td>
              </tr>)}</tbody>
            </table>
          </div>}
  </section>
}
