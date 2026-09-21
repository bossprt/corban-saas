
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
 groups:{id:string;name:string}[]
 summary:{sourceRows:number;expandedRows:number;tables:string[];components:string[];hasDeferred:boolean;hasPlastic:boolean;hasBonus:boolean;hasGenericRepasseColumns:boolean;genericRepasseSlots:string[]}
 issues:{line:number;code:string;detail?:string;message:string}[]
 economics:{table:string;contract:string;termMin:number;termMax:number;component:string;group:string;groupId:string;componentTypeId:string;mode:'share_of_received'|'direct'|'exclude';sharePct:string|null;receivedKind:'percentage'|'fixed_brl';gross:string;net:string;payout:string;retained:string|null;payoutKind:'percentage'|'fixed_brl'|null;compatible:boolean}[]
 suggestedPolicy:{versionId:string;policyId:string;name:string;version:number;discount:string;specificity:number;scopeLabel:string}|null
 ambiguousPolicies:{versionId:string;policyId:string;name:string;version:number;discount:string;specificity:number;scopeLabel:string}[]
 policyUsedForPreview:string|null
 remittance:{mode:'partial'|'complete';effectiveFrom:string|null;scope:string|null;existingTables:string[];missingTables:string[];newTables:string[]}
 repasses:{table:string;contract:string;termMin:number;termMax:number;group_id:string;component_type_id:string;raw_value:string;rule_hint:'share_of_received'|'direct'|'unknown';value_kind_hint:'percentage'|'fixed_brl'|null;source_slot:string|null}[]
 repassComparisons:{table:string;contract:string;termMin:number;termMax:number;groupId:string;componentTypeId:string;slot:string;external:string;externalKind:'percentage'|'fixed_brl'|null;internal:string|null;status:'match'|'different'|'incompatible_unit'|'incompatible_semantics'|'no_internal_rule'}[]
 sample:{bank:string;agreement:string;table:string;contract:string;termMin:number;termMax:number;rate:string|null;factor:string|null;components:number}[]
}
const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950 disabled:opacity-50'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm disabled:opacity-50'

export function SmartImportClient({providers,policies}:{providers:Provider[];policies:Policy[]}){
 const [file,setFile]=useState<File|null>(null)
 const [origin,setOrigin]=useState<'own'|'third_party'>('own')
 const [provider,setProvider]=useState('')
 const [policy,setPolicy]=useState('')
 const [remittanceMode,setRemittanceMode]=useState<'partial'|'complete'>('partial')
 const [remittanceEffectiveFrom,setRemittanceEffectiveFrom]=useState('')
 const [preview,setPreview]=useState<Preview|null>(null)
 const [busy,setBusy]=useState(false)
 const [message,setMessage]=useState('')
 const [ignoreLegacy,setIgnoreLegacy]=useState(false)
 const [headerMap,setHeaderMap]=useState<Record<string,string>>({})
 const [contractMap,setContractMap]=useState<Record<string,string>>({})
 const [repassMap,setRepassMap]=useState<Record<string,{group_id:string;rule_hint:string;value_kind_hint:string}>>({})
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
   if(remittanceMode==='complete'&&!remittanceEffectiveFrom){setMessage('Informe a data de início da nova vigência para a remessa completa.');setBusy(false);return}
   const fd=new FormData();fd.set('file',file);fd.set('policy_version_id',policy);fd.set('remittance_mode',remittanceMode);fd.set('remittance_effective_from',remittanceEffectiveFrom);fd.set('production_origin',origin);fd.set('provider_id',origin==='third_party'?provider:'');fd.set('header_map',JSON.stringify(Object.fromEntries(Object.entries(headerMap).filter(([,v])=>v!=='').map(([k,v])=>[k,Number(v)]))));fd.set('contract_type_map',JSON.stringify(Object.fromEntries(Object.entries(contractMap).filter(([,v])=>v!==''))));fd.set('generic_repass_map',JSON.stringify(Object.fromEntries(Object.entries(repassMap).filter(([,v])=>v.group_id&&v.rule_hint&&v.value_kind_hint))))
   const res=await fetch('/api/comercial/importacao-inteligente/preview',{method:'POST',body:fd})
   const body=await res.json()
   if(!res.ok){setMessage(body.error??'Não foi possível analisar.');return}
   setPreview(body)
   if(!policy&&body.suggestedPolicy?.versionId)setPolicy(body.suggestedPolicy.versionId)
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
   fd.set('policy_version_id',policy);fd.set('remittance_mode',remittanceMode);fd.set('remittance_effective_from',remittanceEffectiveFrom);fd.set('ignore_legacy_repasses',String(ignoreLegacy));fd.set('header_map',JSON.stringify(Object.fromEntries(Object.entries(headerMap).filter(([,v])=>v!=='').map(([k,v])=>[k,Number(v)]))));fd.set('contract_type_map',JSON.stringify(Object.fromEntries(Object.entries(contractMap).filter(([,v])=>v!==''))));fd.set('generic_repass_map',JSON.stringify(Object.fromEntries(Object.entries(repassMap).filter(([,v])=>v.group_id&&v.rule_hint&&v.value_kind_hint))))
   const res=await fetch('/api/comercial/importacao-inteligente/apply',{method:'POST',body:fd})
   const body=await res.json()
   if(!res.ok){setMessage(body.error??'Importação recusada.');return}
   const r=body.result??{}
   setMessage('Atualização aplicada: '+String(r.created_tables??0)+' tabela(s) nova(s), '+String(r.upserted_conditions??0)+' condição(ões), '+String(r.published_versions??0)+' versão(ões) publicada(s)/agendada(s) e '+String(r.retired_absent_versions??0)+' versão(ões) de tabela ausente encerrada(s). O histórico anterior foi preservado.')
  }finally{setBusy(false)}
 }

 return <div className="space-y-5">
  <div className="rounded-2xl border border-slate-800 bg-slate-900 p-5">
   <h2 className="font-semibold">1. Envie o arquivo e escolha a regra</h2>
   <p className="mt-1 text-xs text-slate-400">CSV, XLSX, XLS antigo ou PDF com texto. Até 2 MB para planilhas e 5 MB para PDF. A prévia não grava nada.</p>
   <div className="mt-3 grid gap-2 md:grid-cols-2">
    <select value={policy} onChange={e=>{setPolicy(e.target.value);setPreview(null)}} className={field+' md:col-span-2'}><option value="">Deixar o Corban sugerir a regra pelo escopo</option>{policies.map(p=><option key={p.versionId} value={p.versionId}>{p.name} · v{p.version} · imposto/desconto {p.discount}%</option>)}</select>
    <label className="text-xs text-slate-400">Tipo da atualização<select value={remittanceMode} onChange={e=>{setRemittanceMode(e.target.value as 'partial'|'complete');setPreview(null)}} className={field+' mt-1 w-full'}><option value="partial">Atualização parcial — tabelas ausentes não mudam</option><option value="complete">Remessa completa — tabelas ausentes deixam de vigorar</option></select></label>
    <label className="text-xs text-slate-400">Início da nova vigência<input type="date" disabled={remittanceMode!=='complete'} value={remittanceEffectiveFrom} onChange={e=>{setRemittanceEffectiveFrom(e.target.value);setPreview(null)}} className={field+' mt-1 w-full disabled:opacity-50'}/></label>
    <input type="file" accept=".csv,.xlsx,.xls,.pdf,text/csv" onChange={e=>{setFile(e.target.files?.[0]??null);setPreview(null);setHeaderMap({});setContractMap({});setRepassMap({});setMessage('')}} className="block text-sm"/>
    <button disabled={!file||busy||(remittanceMode==='complete'&&!remittanceEffectiveFrom)} onClick={runPreview} className={ghost}>{busy?'Analisando...':'Analisar sem gravar'}</button>
   </div>
   <p className="mt-3 text-xs text-slate-500">Use <b>Remessa completa</b> somente quando o arquivo representa todo o catálogo vigente daquele Banco + Convênio. Na parcial, ausência nunca encerra uma tabela.</p>
  </div>

  {preview&&<div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/5 p-5">
   <h2 className="font-semibold text-emerald-200">2. Prévia</h2>
   <div className="mt-3 grid gap-3 md:grid-cols-4 text-sm">
    <div><span className="text-slate-500">Linhas origem</span><div className="text-lg font-semibold">{preview.summary.sourceRows}</div></div>
    <div><span className="text-slate-500">Condições</span><div className="text-lg font-semibold">{preview.summary.expandedRows}</div></div>
    <div><span className="text-slate-500">Tabelas</span><div className="text-lg font-semibold">{preview.summary.tables.length}</div></div>
    <div><span className="text-slate-500">Componentes detectados</span><div className="text-lg font-semibold">{preview.summary.components.length}</div></div>
   </div>
   <div className="mt-3 text-xs text-slate-300">{preview.summary.tables.slice(0,8).map(x=><div key={x}>• {x}</div>)}</div>
   <div className="mt-4 rounded-xl border border-slate-800 p-4 text-sm">
    <div className="font-semibold">Impacto da atualização</div>
    <div className="mt-1 text-xs text-slate-400">{preview.remittance.mode==='complete'?'Remessa completa':'Atualização parcial'}{preview.remittance.scope?' · '+preview.remittance.scope:''}{preview.remittance.effectiveFrom?' · nova vigência '+preview.remittance.effectiveFrom:''}</div>
    {!!preview.remittance.newTables.length&&<div className="mt-3"><span className="text-emerald-300">Novas tabelas:</span> {preview.remittance.newTables.join(', ')}</div>}
    {preview.remittance.mode==='complete'&&!!preview.remittance.missingTables.length&&<div className="mt-3 rounded-lg border border-amber-500/30 bg-amber-500/5 p-3"><div className="font-semibold text-amber-200">Tabelas atuais ausentes nesta remessa</div><p className="mt-1 text-xs text-slate-400">Elas não serão apagadas. A vigência será encerrada no início informado e propostas/simulações anteriores manterão a versão histórica.</p><div className="mt-2 text-xs">{preview.remittance.missingTables.map(x=><div key={x}>• {x}</div>)}</div></div>}
    {preview.remittance.mode==='partial'&&<p className="mt-3 text-xs text-slate-400">Tabelas que não vieram neste arquivo permanecerão exatamente como estão.</p>}
   </div>
   {preview.suggestedPolicy&&<div className="mt-4 rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-4 text-sm"><div className="font-semibold text-emerald-200">Regra sugerida automaticamente</div><div className="mt-1">{preview.suggestedPolicy.name} · v{preview.suggestedPolicy.version}</div><div className="mt-1 text-xs text-slate-400">{preview.suggestedPolicy.scopeLabel} · imposto/desconto {preview.suggestedPolicy.discount}%</div></div>}
   {!!preview.ambiguousPolicies?.length&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm"><div className="font-semibold text-amber-200">Há mais de uma regra igualmente específica</div><p className="mt-1 text-xs text-slate-400">Escolha explicitamente antes de importar; o Corban não desempata regra financeira por conta própria.</p><select value={policy} onChange={e=>setPolicy(e.target.value)} className={field+' mt-3 w-full'}><option value="">Escolha a regra</option>{preview.ambiguousPolicies.map(p=><option key={p.versionId} value={p.versionId}>{p.name} · v{p.version} · {p.scopeLabel}</option>)}</select>{policy&&<button onClick={runPreview} className={ghost+' mt-3'}>Recalcular prévia com esta regra</button>}</div>}
   {!!preview.issues.length&&<div className="mt-4 space-y-2">{preview.issues.map((x,i)=><div key={i} className={x.code==='generic_repass_requires_mapping'?'rounded-lg border border-amber-500/30 p-3 text-xs text-amber-200':'rounded-lg border border-red-500/30 p-3 text-xs text-red-200'}>Linha {x.line}: {x.message}{x.detail?' — '+x.detail:''}</div>)}</div>}
   {preview.headers?.length>0&&preview.issues.some(x=>['missing_bank','missing_agreement','missing_table','missing_contract','missing_term','missing_rate_coefficient_or_factor'].includes(x.code))&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4"><h3 className="text-sm font-semibold text-amber-200">Mapear colunas manualmente</h3><p className="mt-1 text-xs text-slate-400">Use somente quando o arquivo chama uma coluna por outro nome. O Corban reanalisa antes de permitir qualquer gravação.</p><div className="mt-3 grid gap-2 md:grid-cols-2">{[
    ['bank','Banco / Instituição'],['agreement','Convênio'],['table','Produto / Tabela'],['contract','Tipo de Contrato'],
    ['term','Prazo'],['termMin','Prazo Inicial'],['termMax','Prazo Final'],['rate','Taxa'],['coefficient','Coeficiente'],['factor','Fator'],
   ].filter(([k])=>k==='term'||k==='termMin'||k==='termMax'?preview.issues.some(x=>x.code==='missing_term'):k==='rate'||k==='coefficient'||k==='factor'?preview.issues.some(x=>x.code==='missing_rate_coefficient_or_factor'):preview.issues.some(x=>x.code==='missing_'+k)).map(([k,label])=><label key={k} className="text-xs text-slate-400">{label}<select value={headerMap[k]??''} onChange={e=>setHeaderMap(m=>({...m,[k]:e.target.value}))} className={field+' mt-1 w-full'}><option value="">Selecione a coluna</option>{preview.headers.map(h=><option key={h.index} value={String(h.index)}>{h.label}</option>)}</select></label>)}</div><button disabled={busy} onClick={runPreview} className={ghost+' mt-3'}>{busy?'Reanalisando...':'Reanalisar com mapeamento'}</button></div>}
   {preview.issues.some(x=>x.code==='unknown_contract_type')&&preview.contractTypes?.length>0&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4"><h3 className="text-sm font-semibold text-amber-200">Mapear Tipo de Contrato</h3><p className="mt-1 text-xs text-slate-400">O Corban não cria nem adivinha um tipo. Vincule cada nome usado no arquivo a um Tipo de Contrato já habilitado.</p><div className="mt-3 grid gap-2 md:grid-cols-2">{[...new Set(preview.issues.filter(x=>x.code==='unknown_contract_type').map(x=>x.detail).filter((x):x is string=>!!x))].map(source=><label key={source} className="text-xs text-slate-400">{source}<select value={contractMap[source]??''} onChange={e=>setContractMap(m=>({...m,[source]:e.target.value}))} className={field+' mt-1 w-full'}><option value="">Selecione o tipo correto</option>{preview.contractTypes.map(t=><option key={t.id} value={t.id}>{t.name}</option>)}</select></label>)}</div><button disabled={busy} onClick={runPreview} className={ghost+' mt-3'}>{busy?'Reanalisando...':'Reanalisar tipos'}</button></div>}
   {!!preview.sample.length&&<div className="mt-4 overflow-x-auto"><table className="min-w-[760px] w-full text-xs"><thead className="text-slate-500"><tr><th className="p-2 text-left">Instituição</th><th>Convênio</th><th>Tabela</th><th>Tipo</th><th>Prazo</th><th>Taxa</th><th>Fator</th></tr></thead><tbody>{preview.sample.map((r,i)=><tr key={i} className="border-t border-slate-800"><td className="p-2">{r.bank}</td><td>{r.agreement}</td><td>{r.table}</td><td>{r.contract}</td><td>{r.termMin===r.termMax?r.termMin+'x':r.termMin+'–'+r.termMax+'x'}</td><td>{r.rate??'—'}</td><td>{r.factor??'—'}</td></tr>)}</tbody></table></div>}
   {!!preview.economics?.length&&<div className="mt-5"><h3 className="text-sm font-semibold text-emerald-200">Prévia econômica por grupo</h3><p className="mt-1 text-xs text-slate-400">Cada grupo é um cenário alternativo. Os valores dos grupos não são somados entre si.</p><div className="mt-2 overflow-x-auto"><table className="min-w-[980px] w-full text-xs"><thead className="text-slate-500"><tr><th className="p-2 text-left">Tabela</th><th>Tipo/prazo</th><th>Componente</th><th>Grupo</th><th>Empresa recebe</th><th>Após imposto</th><th>Grupo recebe</th><th>Empresa retém</th></tr></thead><tbody>{preview.economics.map((e,i)=>{const u=(k:'percentage'|'fixed_brl'|null,v:string|null)=>v===null?'—':(k==='fixed_brl'?'R$ ':'')+v+(k==='percentage'?'%':'');return <tr key={i} className="border-t border-slate-800"><td className="p-2">{e.table}</td><td>{e.contract} {e.termMin===e.termMax?e.termMin+'x':e.termMin+'–'+e.termMax+'x'}</td><td>{e.component}</td><td>{e.group}</td><td>{u(e.receivedKind,e.gross)}</td><td>{u(e.receivedKind,e.net)}</td><td>{u(e.payoutKind,e.payout)}</td><td>{e.retained===null?'unidades diferentes':u(e.receivedKind,e.retained)}</td></tr>})}</tbody></table></div></div>}
   {!!preview.repasses?.length&&<div className="mt-5"><h3 className="text-sm font-semibold text-amber-200">Valores externos mapeados</h3><p className="mt-1 text-xs text-slate-400">Estes valores vêm do arquivo. Eles servem para comparação e não substituem automaticamente a regra interna do Corban.</p><div className="mt-2 overflow-x-auto"><table className="min-w-[760px] w-full text-xs"><thead className="text-slate-500"><tr><th className="p-2 text-left">Tabela</th><th>Tipo/prazo</th><th>Slot</th><th>Grupo</th><th>Valor externo</th><th>Interpretação</th></tr></thead><tbody>{preview.repasses.map((r,i)=><tr key={i} className="border-t border-slate-800"><td className="p-2">{r.table}</td><td>{r.contract} {r.termMin===r.termMax?r.termMin+'x':r.termMin+'–'+r.termMax+'x'}</td><td>{r.source_slot?'Repasse '+r.source_slot:'Nome explícito'}</td><td>{preview.groups.find(g=>g.id===r.group_id)?.name??'Grupo'}</td><td>{r.value_kind_hint==='fixed_brl'?'R$ ':''}{r.raw_value}{r.value_kind_hint==='percentage'?'%':''}</td><td>{r.rule_hint==='direct'?'Valor final pago':r.rule_hint==='share_of_received'?'% da comissão recebida':'Não informado'}</td></tr>)}</tbody></table></div></div>}
   {!!preview.repassComparisons?.length&&<div className="mt-5"><h3 className="text-sm font-semibold text-sky-200">Comparação externa × regra interna</h3><p className="mt-1 text-xs text-slate-400">Diferença não altera a regra do Corban. Ela apenas mostra onde o arquivo externo e a política interna divergem.</p><div className="mt-2 overflow-x-auto"><table className="min-w-[820px] w-full text-xs"><thead className="text-slate-500"><tr><th className="p-2 text-left">Tabela</th><th>Tipo/prazo</th><th>Grupo</th><th>Repasse</th><th>Externo</th><th>Interno</th><th>Situação</th></tr></thead><tbody>{preview.repassComparisons.map((r,i)=>{const label=r.status==='match'?'Confere':r.status==='different'?'Difere':r.status==='incompatible_unit'?'Unidade diferente':r.status==='incompatible_semantics'?'Regra diferente':'Sem regra interna';const unit=r.externalKind==='fixed_brl'?'R$ ':'';const suffix=r.externalKind==='percentage'?'%':'';return <tr key={i} className="border-t border-slate-800"><td className="p-2">{r.table}</td><td>{r.contract} {r.termMin===r.termMax?r.termMin+'x':r.termMin+'–'+r.termMax+'x'}</td><td>{preview.groups.find(g=>g.id===r.groupId)?.name??'Grupo'}</td><td>Repasse {r.slot}</td><td>{unit}{r.external}{suffix}</td><td>{r.internal===null?'—':unit+r.internal+suffix}</td><td>{label}</td></tr>})}</tbody></table></div></div>}
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

   {preview.summary.hasGenericRepasseColumns&&<div className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-amber-100"><div className="font-semibold">Repasse 1/2/3 detectado</div><p className="mt-1 text-xs text-slate-400">O Corban nunca decide sozinho quem é Repasse 1, 2 ou 3. Você pode mapear os slots para comparar com a regra interna ou ignorá-los.</p><div className="mt-3 space-y-3">{preview.summary.genericRepasseSlots.map(label=>{const slot=label.replace(/\D/g,'');const m=repassMap[slot]??{group_id:'',rule_hint:'',value_kind_hint:''};return <div key={slot} className="grid gap-2 rounded-lg border border-slate-800 p-3 md:grid-cols-3"><div className="font-medium">{label}</div><select value={m.group_id} onChange={e=>setRepassMap(x=>({...x,[slot]:{...m,group_id:e.target.value}}))} className={field}><option value="">Grupo de Comissão</option>{preview.groups.map(g=><option key={g.id} value={g.id}>{g.name}</option>)}</select><select value={m.rule_hint} onChange={e=>setRepassMap(x=>({...x,[slot]:{...m,rule_hint:e.target.value}}))} className={field}><option value="">Como interpretar</option><option value="direct">Valor final pago ao grupo</option><option value="share_of_received">% da comissão recebida</option></select><select value={m.value_kind_hint} onChange={e=>setRepassMap(x=>({...x,[slot]:{...m,value_kind_hint:e.target.value}}))} className={field+' md:col-start-2'}><option value="">Unidade</option><option value="percentage">%</option>{m.rule_hint!=='share_of_received'&&<option value="fixed_brl">R$</option>}</select></div>})}</div><div className="mt-3 flex flex-wrap gap-2"><button disabled={busy||!preview.summary.genericRepasseSlots.every(label=>{const m=repassMap[label.replace(/\D/g,'')];return !!m?.group_id&&!!m?.rule_hint&&!!m?.value_kind_hint})} onClick={()=>{setIgnoreLegacy(false);runPreview()}} className={ghost}>Reanalisar com mapeamento</button><label className="flex items-center text-xs"><input type="checkbox" checked={ignoreLegacy} onChange={e=>setIgnoreLegacy(e.target.checked)} className="mr-2"/>Ignorar os Repasse 1/2/3 e usar somente a regra interna</label></div></div>}

   <div className="mt-4 rounded-xl border border-slate-800 p-4 text-xs text-slate-400">Ao confirmar, a atualização é aplicada de forma atômica. Versões futuras ficam agendadas pela vigência; versões anteriores e propostas antigas permanecem preservadas no histórico.</div>
   <button disabled={busy||preview.issues.some(x=>x.code!=='generic_repass_requires_mapping')||(preview.issues.some(x=>x.code==='generic_repass_requires_mapping')&&!ignoreLegacy)||(preview.ambiguousPolicies?.length>0&&!policy)} onClick={apply} className={btn+' mt-4'}>{busy?'Importando...':'Confirmar e importar'}</button>
  </div>}

  {message&&<div className="rounded-xl border border-slate-700 bg-slate-900 p-4 text-sm">{message}</div>}
 </div>
}
