
'use client'
import { useMemo, useState } from 'react'

type Provider={id:string;name:string;provider_type:string}
type Policy={versionId:string;name:string;version:number;discount:string}
type Preview={
 ok:boolean
 fileName:string
 headers:{index:number;label:string}[]
 headerMapApplied:Record<string,number>
 contractTypes:{id:string;name:string}[]
 summary:{sourceRows:number;expandedRows:number;tables:string[];components:string[];hasDeferred:boolean;hasPlastic:boolean;hasBonus:boolean;hasGenericRepasseColumns:boolean}
 issues:{line:number;code:string;detail?:string;message:string}[]
 economics:{table:string;contract:string;term:number;component:string;group:string;receivedKind:'percentage'|'fixed_brl';gross:string;net:string;payout:string;retained:string|null;payoutKind:'percentage'|'fixed_brl'|null;compatible:boolean}[]
 sample:{bank:string;agreement:string;table:string;contract:string;term:number;rate:string|null;factor:string|null;components:number}[]
}
const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950 disabled:opacity-50'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm disabled:opacity-50'

export function SmartImportClient({providers,policies}:{providers:Provider[];policies:Policy[]}){
 const [file,setFile]=useState<File|null>(null)
 const [origin,setOrigin]=useState<'own'|'third_party'>('own')
 const [provider,setProvider]=useState('')
 const [policy,setPolicy]=useState('')
 const [preview,setPreview]=useState<Preview|null>(null)
 const [busy,setBusy]=useState(false)
 const [message,setMessage]=useState('')
 const [ignoreLegacy,setIgnoreLegacy]=useState(false)
 const [headerMap,setHeaderMap]=useState<Record<string,string>>({})
 const [contractMap,setContractMap]=useState<Record<string,string>>({})
 const [answers,setAnswers]=useState({deferred:false,plastic:false,bonus:false})

 const optionalQuestions=useMemo(()=>preview?[
  preview.summary.hasDeferred&&['deferred','Diferido'],
  preview.summary.hasPlastic&&['plastic','Plástico'],
  preview.summary.hasBonus&&['bonus','Bônus'],
 ].filter(Boolean) as [keyof typeof answers,string][]:[],[preview])

 async function runPreview(){
  if(!file)return
  setBusy(true);setMessage('');setPreview(null);setIgnoreLegacy(false);setAnswers({deferred:false,plastic:false,bonus:false})
  try{
   const fd=new FormData();fd.set('file',file);fd.set('policy_version_id',policy);fd.set('header_map',JSON.stringify(Object.fromEntries(Object.entries(headerMap).filter(([,v])=>v!=='').map(([k,v])=>[k,Number(v)]))));fd.set('contract_type_map',JSON.stringify(Object.fromEntries(Object.entries(contractMap).filter(([,v])=>v!==''))));fd.set('contract_type_map',JSON.stringify(Object.fromEntries(Object.entries(contractMap).filter(([,v])=>v!==''))))
   const res=await fetch('/api/comercial/importacao-inteligente/preview',{method:'POST',body:fd})
   const body=await res.json()
   if(!res.ok){setMessage(body.error??'Não foi possível analisar.');return}
   setPreview(body)
  }finally{setBusy(false)}
 }

 async function apply(){
  if(!file||!preview)return
  if(origin==='third_party'&&!provider){setMessage('Escolha a empresa de origem.');return}
  if(optionalQuestions.some(([k])=>!answers[k])){setMessage('Responda as perguntas sobre os componentes detectados antes de importar.');return}
  setBusy(true);setMessage('')
  try{
   const fd=new FormData()
   fd.set('file',file);fd.set('production_origin',origin);fd.set('provider_id',origin==='third_party'?provider:'')
   fd.set('policy_version_id',policy);fd.set('ignore_legacy_repasses',String(ignoreLegacy));fd.set('header_map',JSON.stringify(Object.fromEntries(Object.entries(headerMap).filter(([,v])=>v!=='').map(([k,v])=>[k,Number(v)]))))
   const res=await fetch('/api/comercial/importacao-inteligente/apply',{method:'POST',body:fd})
   const body=await res.json()
   if(!res.ok){setMessage(body.error??'Importação recusada.');return}
   const r=body.result??{}
   setMessage('Importação concluída: '+String(r.created_tables??0)+' tabela(s) nova(s), '+String(r.upserted_conditions??0)+' condição(ões), '+String(r.components??0)+' componente(s) e '+String(r.factors??0)+' fator(es). As tabelas ficaram em rascunho para revisão.')
  }finally{setBusy(false)}
 }

 return <div className="space-y-5">
  <div className="rounded-2xl border border-slate-800 bg-slate-900 p-5">
   <h2 className="font-semibold">1. Envie o arquivo e escolha a regra</h2>
   <p className="mt-1 text-xs text-slate-400">CSV, XLSX, XLS antigo ou PDF com texto. Até 2 MB para planilhas e 5 MB para PDF. A prévia não grava nada.</p>
   <div className="mt-3 grid gap-2 md:grid-cols-2"><select value={policy} onChange={e=>{setPolicy(e.target.value);setPreview(null)}} className={field+' md:col-span-2'}><option value="">Sem regra interna na prévia</option>{policies.map(p=><option key={p.versionId} value={p.versionId}>{p.name} · v{p.version} · imposto/desconto {p.discount}%</option>)}</select><input type="file" accept=".csv,.xlsx,.xls,.pdf,text/csv" onChange={e=>{setFile(e.target.files?.[0]??null);setPreview(null);setHeaderMap({});setContractMap({});setMessage('')}} className="block text-sm"/><button disabled={!file||busy} onClick={runPreview} className={ghost}>{busy?'Analisando...':'Analisar sem gravar'}</button></div>
  </div>

  {preview&&<div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/5 p-5">
   <h2 className="font-semibold text-emerald-200">2. Prévia</h2>
   <div className="mt-3 grid gap-3 md:grid-cols-4 text-sm">
    <div><span className="text-slate-500">Linhas origem</span><div className="text-lg font-semibold">{preview.summary.sourceRows}</div></div>
    <div><span className="text-slate-500">Condições após prazos</span><div className="text-lg font-semibold">{preview.summary.expandedRows}</div></div>
    <div><span className="text-slate-500">Tabelas</span><div className="text-lg font-semibold">{preview.summary.tables.length}</div></div>
    <div><span className="text-slate-500">Componentes detectados</span><div className="text-lg font-semibold">{preview.summary.components.length}</div></div>
   </div>
   <div className="mt-3 text-xs text-slate-300">{preview.summary.tables.slice(0,8).map(x=><div key={x}>• {x}</div>)}</div>
   {!!preview.issues.length&&<div className="mt-4 space-y-2">{preview.issues.map((x,i)=><div key={i} className={x.code==='generic_repass_requires_mapping'?'rounded-lg border border-amber-500/30 p-3 text-xs text-amber-200':'rounded-lg border border-red-500/30 p-3 text-xs text-red-200'}>Linha {x.line}: {x.message}{x.detail?' — '+x.detail:''}</div>)}</div>}
   {preview.headers?.length>0&&preview.issues.some(x=>['missing_bank','missing_agreement','missing_table','missing_contract','missing_term','missing_rate_coefficient_or_factor'].includes(x.code))&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4"><h3 className="text-sm font-semibold text-amber-200">Mapear colunas manualmente</h3><p className="mt-1 text-xs text-slate-400">Use somente quando o arquivo chama uma coluna por outro nome. O Corban reanalisa antes de permitir qualquer gravação.</p><div className="mt-3 grid gap-2 md:grid-cols-2">{[
    ['bank','Banco / Instituição'],['agreement','Convênio'],['table','Produto / Tabela'],['contract','Tipo de Contrato'],
    ['term','Prazo'],['termMin','Prazo Inicial'],['termMax','Prazo Final'],['rate','Taxa'],['coefficient','Coeficiente'],['factor','Fator'],
   ].filter(([k])=>k==='term'||k==='termMin'||k==='termMax'?preview.issues.some(x=>x.code==='missing_term'):k==='rate'||k==='coefficient'||k==='factor'?preview.issues.some(x=>x.code==='missing_rate_coefficient_or_factor'):preview.issues.some(x=>x.code==='missing_'+k)).map(([k,label])=><label key={k} className="text-xs text-slate-400">{label}<select value={headerMap[k]??''} onChange={e=>setHeaderMap(m=>({...m,[k]:e.target.value}))} className={field+' mt-1 w-full'}><option value="">Selecione a coluna</option>{preview.headers.map(h=><option key={h.index} value={String(h.index)}>{h.label}</option>)}</select></label>)}</div><button disabled={busy} onClick={runPreview} className={ghost+' mt-3'}>{busy?'Reanalisando...':'Reanalisar com mapeamento'}</button></div>}
   {preview.issues.some(x=>x.code==='unknown_contract_type')&&preview.contractTypes?.length>0&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4"><h3 className="text-sm font-semibold text-amber-200">Mapear Tipo de Contrato</h3><p className="mt-1 text-xs text-slate-400">O Corban não cria nem adivinha um tipo. Vincule cada nome usado no arquivo a um Tipo de Contrato já habilitado.</p><div className="mt-3 grid gap-2 md:grid-cols-2">{[...new Set(preview.issues.filter(x=>x.code==='unknown_contract_type').map(x=>x.detail).filter((x):x is string=>!!x))].map(source=><label key={source} className="text-xs text-slate-400">{source}<select value={contractMap[source]??''} onChange={e=>setContractMap(m=>({...m,[source]:e.target.value}))} className={field+' mt-1 w-full'}><option value="">Selecione o tipo correto</option>{preview.contractTypes.map(t=><option key={t.id} value={t.id}>{t.name}</option>)}</select></label>)}</div><button disabled={busy} onClick={runPreview} className={ghost+' mt-3'}>{busy?'Reanalisando...':'Reanalisar tipos'}</button></div>}
   {!!preview.sample.length&&<div className="mt-4 overflow-x-auto"><table className="min-w-[760px] w-full text-xs"><thead className="text-slate-500"><tr><th className="p-2 text-left">Instituição</th><th>Convênio</th><th>Tabela</th><th>Tipo</th><th>Prazo</th><th>Taxa</th><th>Fator</th></tr></thead><tbody>{preview.sample.map((r,i)=><tr key={i} className="border-t border-slate-800"><td className="p-2">{r.bank}</td><td>{r.agreement}</td><td>{r.table}</td><td>{r.contract}</td><td>{r.term}x</td><td>{r.rate??'—'}</td><td>{r.factor??'—'}</td></tr>)}</tbody></table></div>}
   {!!preview.economics?.length&&<div className="mt-5"><h3 className="text-sm font-semibold text-emerald-200">Prévia econômica por grupo</h3><p className="mt-1 text-xs text-slate-400">Cada grupo é um cenário alternativo. Os valores dos grupos não são somados entre si.</p><div className="mt-2 overflow-x-auto"><table className="min-w-[980px] w-full text-xs"><thead className="text-slate-500"><tr><th className="p-2 text-left">Tabela</th><th>Tipo/prazo</th><th>Componente</th><th>Grupo</th><th>Empresa recebe</th><th>Após imposto</th><th>Grupo recebe</th><th>Empresa retém</th></tr></thead><tbody>{preview.economics.map((e,i)=>{const u=(k:'percentage'|'fixed_brl'|null,v:string|null)=>v===null?'—':(k==='fixed_brl'?'R$ ':'')+v+(k==='percentage'?'%':'');return <tr key={i} className="border-t border-slate-800"><td className="p-2">{e.table}</td><td>{e.contract} {e.term}x</td><td>{e.component}</td><td>{e.group}</td><td>{u(e.receivedKind,e.gross)}</td><td>{u(e.receivedKind,e.net)}</td><td>{u(e.payoutKind,e.payout)}</td><td>{e.retained===null?'unidades diferentes':u(e.receivedKind,e.retained)}</td></tr>})}</tbody></table></div></div>}
  </div>}

  {preview&&preview.ok&&<div className="rounded-2xl border border-slate-800 bg-slate-900 p-5">
   <h2 className="font-semibold">3. Como o Corban deve aplicar</h2>
   <div className="mt-3 grid gap-2 md:grid-cols-2">
    <select value={origin} onChange={e=>setOrigin(e.target.value as 'own'|'third_party')} className={field}><option value="own">Produção própria</option><option value="third_party">Produção de terceiro</option></select>
    <select disabled={origin==='own'} value={provider} onChange={e=>setProvider(e.target.value)} className={field}><option value="">Empresa de origem</option>{providers.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select>
    <div className={field+' md:col-span-2 text-slate-300'}>{policy?'A regra selecionada na prévia será vinculada às condições importadas.':'Importação sem regra interna selecionada.'}</div>
   </div>

   {!!optionalQuestions.length&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4">
    <strong className="text-sm text-amber-200">O arquivo trouxe componentes que exigem confirmação</strong>
    <div className="mt-2 space-y-2 text-sm">{optionalQuestions.map(([k,label])=><label key={k} className="block"><input type="checkbox" checked={answers[k]} onChange={e=>setAnswers(a=>({...a,[k]:e.target.checked}))} className="mr-2"/>Confirmo que o <b>{label}</b> será importado como componente recebido. {policy?'A regra interna selecionada ficará vinculada à condição.':'Nenhum repasse interno será definido agora.'}</label>)}</div>
   </div>}

   {preview.summary.hasGenericRepasseColumns&&<label className="mt-4 block rounded-xl border border-amber-500/30 p-4 text-sm text-amber-100"><input type="checkbox" checked={ignoreLegacy} onChange={e=>setIgnoreLegacy(e.target.checked)} className="mr-2"/>Confirmo que <b>Repasse 1/2/3...</b> da planilha não será usado como regra interna. O Corban usará somente a política selecionada acima.</label>}

   <div className="mt-4 rounded-xl border border-slate-800 p-4 text-xs text-slate-400">Nenhuma Tabela será publicada automaticamente. A carga cria/atualiza rascunhos para você revisar antes de disponibilizar em simulações.</div>
   <button disabled={busy||preview.issues.some(x=>x.code!=='generic_repass_requires_mapping')||(preview.summary.hasGenericRepasseColumns&&!ignoreLegacy)} onClick={apply} className={btn+' mt-4'}>{busy?'Importando...':'Confirmar e importar'}</button>
  </div>}

  {message&&<div className="rounded-xl border border-slate-700 bg-slate-900 p-4 text-sm">{message}</div>}
 </div>
}
