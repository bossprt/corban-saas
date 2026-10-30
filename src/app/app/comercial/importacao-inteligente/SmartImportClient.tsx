'use client'
import { FileDrop } from '@/components/FileDrop'
import { useMemo, useState } from 'react'
import { Upload } from 'lucide-react'
import { Badge, Card, CardHeader } from '@/components/ui'

type Provider={id:string;name:string;provider_type:string}
type Bank={id:string;name:string}
type Preview={
 ok:boolean
 fileName:string
 validFrom?:string|null
 summary:{sourceRows:number;expandedRows:number;tables:string[];components:string[];hasDeferred:boolean;hasPlastic:boolean;hasBonus:boolean;hasGenericRepasseColumns:boolean;genericRepasseSlots:string[];hasUnmappedRepassValues?:boolean;groups?:string[];hasOriginColumn?:boolean}
 groupOptions:{id:string;name:string}[]
 issues:{line:number;code:string;detail?:string;message:string}[]
 sample:{bank:string;agreement:string;table:string;contract:string;term:number;rate:string|null;factor:string|null;components:number;values?:string;groupValues:number}[]
}
const lbl='text-[13px] font-medium text-ink-soft'
const primary='h-10 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50'
const ghost='h-10 rounded-[10px] border border-line bg-surface px-4 text-sm text-ink hover:bg-surface-muted disabled:opacity-50'
const IGNORE='__ignore__'
// YYYY-MM-DD shown as DD/MM/YYYY (a calendar day: no time zone conversion).
const dateBr=(d:string)=>d.split('-').reverse().join('/')

// Smart import: preview, then map each "Repasse N" column of the file to a seller group (or "Não usar"), then import
// as drafts. The map goes with the preview and with the import, so what is imported is exactly what was previewed.
export function SmartImportClient({providers,banks}:{providers:Provider[];banks:Bank[]}){
 const [file,setFile]=useState<File|null>(null)
 const [origin,setOrigin]=useState<'own'|'third_party'>('own')
 const [provider,setProvider]=useState('')
 const [preview,setPreview]=useState<Preview|null>(null)
 const [busy,setBusy]=useState(false)
 const [message,setMessage]=useState('')
 const [slots,setSlots]=useState<Record<string,string>>({})
 const [base,setBase]=useState('')
 const [bankId,setBankId]=useState('')
 const [answers,setAnswers]=useState({deferred:false,plastic:false,bonus:false})
 const [publish,setPublish]=useState(true)
 const [publishFrom,setPublishFrom]=useState('')

 const optionalQuestions=useMemo(()=>preview?[
  preview.summary.hasDeferred&&['deferred','Diferido'],
  preview.summary.hasPlastic&&['plastic','Plástico'],
  preview.summary.hasBonus&&['bonus','Bônus'],
 ].filter(Boolean) as [keyof typeof answers,string][]:[],[preview])
 const slotNames=preview?.summary.genericRepasseSlots??[]
 const repassMap=()=>JSON.stringify(Object.fromEntries(slotNames.map(s=>{const k=s.replace(/\D/g,'');const v=slots[k];return [k,v===IGNORE?null:v]}).filter(([,v])=>v!==undefined)))
 const allMapped=slotNames.every(s=>!!slots[s.replace(/\D/g,'')])

 async function runPreview(map=repassMap(),chosenBase=base,chosenBank=bankId){
  if(!file)return
  setBusy(true);setMessage('')
  try{
   const fd=new FormData();fd.set('file',file);fd.set('repass_map',map);fd.set('calculation_base',chosenBase);fd.set('bank_id',chosenBank)
   const res=await fetch('/api/comercial/importacao-inteligente/preview',{method:'POST',body:fd})
   const body=await res.json()
   if(!res.ok){setMessage(body.error??'Não foi possível analisar.');setPreview(null);return}
   setPreview(body)
   setPublishFrom(body.validFrom??'')
  }finally{setBusy(false)}
 }

 async function apply(){
  if(!file||!preview)return
  if(!preview.summary.hasOriginColumn&&origin==='third_party'&&!provider){setMessage('Escolha a promotora parceira.');return}
  if(optionalQuestions.some(([k])=>!answers[k])){setMessage('Confirme os tipos de comissão detectados antes de importar.');return}
  if(publish&&!publishFrom){setMessage('Informe o início da vigência para publicar, ou desmarque "Publicar já".');return}
  setBusy(true);setMessage('')
  try{
   const fd=new FormData()
   fd.set('file',file);fd.set('production_origin',preview.summary.hasOriginColumn?'own':origin);fd.set('provider_id',!preview.summary.hasOriginColumn&&origin==='third_party'?provider:'');fd.set('repass_map',repassMap());fd.set('calculation_base',base);fd.set('bank_id',bankId);fd.set('publish_from',publish?publishFrom:'')
   const res=await fetch('/api/comercial/importacao-inteligente/apply',{method:'POST',body:fd})
   const body=await res.json()
   if(!res.ok){setMessage(body.error??'Importação recusada.');return}
   const r=body.result??{}
   const done=`Importação concluída: ${r.created_tables??0} tabela(s) nova(s), ${r.upserted_conditions??0} linha(s), ${r.components??0} valor(es) da empresa e ${r.factors??0} fator(es).`
   setMessage(body.published?`${done} ${body.published} tabela(s) publicada(s) a partir de ${dateBr(body.publishFrom)}.`
    :body.publishError?`${done} As tabelas ficaram em rascunho e não foram publicadas: ${body.publishError}`
    :`${done} As tabelas ficaram em rascunho para você conferir e publicar.`)
  }finally{setBusy(false)}
 }

 const PENDING=['generic_repass_requires_mapping','calculation_base_required','bank_choice_required']
 const blocking=preview?.issues.filter(x=>!PENDING.includes(x.code))??[]
 const needsBase=!!base||!!preview?.issues.some(x=>x.code==='calculation_base_required')
 const needsBank=!!bankId||!!preview?.issues.some(x=>x.code==='bank_choice_required')
 return <div className="grid gap-4">
  <Card>
   <CardHeader title="1. Envie a planilha" />
   <div className="px-5 pb-5 pt-2">
    <p className="text-[13px] text-ink-soft">CSV, XLSX ou XLS. No modelo do Corban, no da 2tech (Empresa + Repasse 1…5) ou a tabela de comissão da Bevicred do jeito que vem do portal.</p>
    <div className="mt-3 flex flex-wrap items-center gap-2">
     <div className="min-w-64 flex-1"><FileDrop accept=".csv,.xlsx,.xls,.pdf,text/csv" ariaLabel="Planilha" hint="CSV, XLSX ou XLS" onChange={fs=>{setFile(fs[0]??null);setPreview(null);setSlots({});setBase('');setBankId('');setMessage('')}} /></div>
     <button disabled={!file||busy} onClick={()=>{setSlots({});setBase('');setBankId('');void runPreview('{}','','')}} className={primary}><Upload size={15} className="mr-1.5 inline" aria-hidden />{busy?'Lendo...':'Ler planilha'}</button>
    </div>
   </div>
  </Card>

  {preview&&<Card>
   <CardHeader title="2. Prévia" action={<span className="text-xs text-muted">{preview.fileName}</span>} />
   <div className="grid gap-3 px-5 pt-3 sm:grid-cols-4">
    {[['Linhas no arquivo',preview.summary.sourceRows],['Linhas após os prazos',preview.summary.expandedRows],['Tabelas',preview.summary.tables.length],['Grupos com valores',preview.summary.groups?.length??0]].map(([k,v])=>(
     <div key={String(k)} className="rounded-[12px] border border-line px-4 py-3"><div className="text-xs text-muted">{k}</div><div className="num text-xl font-semibold text-ink">{v}</div></div>
    ))}
   </div>
   {!!preview.summary.groups?.length&&<p className="px-5 pt-3 text-[13px] text-ink-soft">Grupos: {preview.summary.groups.join(', ')}</p>}

   {!!slotNames.length&&<div className="mx-5 mt-4 rounded-[12px] border border-[#FDE68A] bg-[#FFFBEB] p-4">
    <strong className="text-sm text-[#92400E]">A planilha usa colunas Repasse. De qual grupo é cada uma?</strong>
    <div className="mt-3 grid gap-3 sm:grid-cols-3">{slotNames.map(s=>{const k=s.replace(/\D/g,'');return(
     <label key={k} className={lbl}>{s}
      <select aria-label={s} value={slots[k]??''} onChange={e=>setSlots(m=>({...m,[k]:e.target.value}))} className="field mt-1.5">
       <option value="" disabled>Escolha</option>
       {preview.groupOptions.map(g=><option key={g.id} value={g.id}>{g.name}</option>)}
       <option value={IGNORE}>Não usar esta coluna</option>
      </select>
     </label>)})}
    </div>
    <button disabled={!allMapped||busy} onClick={()=>void runPreview()} className={`${ghost} mt-3`}>Aplicar e ver a prévia de novo</button>
   </div>}

   {needsBank&&<div className="mx-5 mt-4 rounded-[12px] border border-[#FDE68A] bg-[#FFFBEB] p-4">
    <strong className="text-sm text-[#92400E]">A tabela da Bevicred não diz o banco. De qual banco são estas tabelas?</strong>
    <div className="mt-3 flex flex-wrap items-end gap-3">
     <label className={lbl}>Banco<select aria-label="Banco" value={bankId} onChange={e=>setBankId(e.target.value)} className="field mt-1.5"><option value="" disabled>Escolha</option>{banks.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
     <button disabled={!bankId||busy} onClick={()=>void runPreview()} className={ghost}>Aplicar e ver a prévia de novo</button>
    </div>
    {!banks.length&&<p className="mt-2 text-xs text-[#92400E]">Nenhum banco cadastrado: cadastre o banco em Cadastros antes.</p>}
   </div>}

   {needsBase&&<div className="mx-5 mt-4 rounded-[12px] border border-[#FDE68A] bg-[#FFFBEB] p-4">
    <strong className="text-sm text-[#92400E]">A planilha não diz a base de cálculo. As comissões em % desta planilha são sobre qual valor?</strong>
    <div className="mt-3 flex flex-wrap items-end gap-3">
     <label className={lbl}>Base de cálculo<select aria-label="Base de cálculo" value={base} onChange={e=>setBase(e.target.value)} className="field mt-1.5"><option value="" disabled>Escolha</option><option value="BRUTO">Bruto (valor do contrato)</option><option value="LÍQUIDO">Líquido (valor liberado)</option></select></label>
     <button disabled={!base||busy} onClick={()=>void runPreview()} className={ghost}>Aplicar e ver a prévia de novo</button>
    </div>
   </div>}

   {!!blocking.length&&<div className="mx-5 mt-4 grid gap-2">{blocking.map((x,i)=><div key={i} role="alert" className="rounded-[10px] border border-[#FCA5A5] bg-[#FEF2F2] p-3 text-[13px] text-[#991B1B]">{x.line>1?`Linha ${x.line}: `:''}{x.message}{x.detail?` — ${x.detail}`:''}</div>)}</div>}

   {!!preview.sample.length&&<div className="mt-4 overflow-x-auto px-2 pb-2"><table className="w-full min-w-[720px] text-left text-[13px]">
    <thead className="text-xs text-muted"><tr>{['Banco','Convênio','Tabela','Tipo','Prazo','Taxa','Fator','Valores empresa','Valores grupos'].map(h=><th key={h} className="px-3 py-2 font-medium">{h}</th>)}</tr></thead>
    <tbody>{preview.sample.map((r,i)=><tr key={i} className="border-t border-line"><td className="px-3 py-2">{r.bank}</td><td className="px-3 py-2">{r.agreement}</td><td className="px-3 py-2">{r.table}</td><td className="px-3 py-2">{r.contract}</td><td className="num px-3 py-2">{r.term}x</td><td className="num px-3 py-2">{r.rate??'—'}</td><td className="num px-3 py-2">{r.factor??'—'}</td><td className="num px-3 py-2">{r.values||r.components}</td><td className="num px-3 py-2">{r.groupValues}</td></tr>)}</tbody>
   </table></div>}
   <div className="h-3" />
  </Card>}

  {preview&&!blocking.length&&<Card>
   <CardHeader title="3. Importar" />
   <div className="grid gap-3 px-5 pb-5 pt-3">
    {preview.summary.hasOriginColumn ? <p className="text-[13px] text-ink-soft">A origem de cada linha vem da coluna <b className="text-ink">Promotora parceira</b> da planilha (vazio = produção própria).</p> :
    <div className="grid gap-3 sm:grid-cols-2">
     <label className={lbl}>Origem da produção<select value={origin} onChange={e=>setOrigin(e.target.value as 'own'|'third_party')} className="field mt-1.5"><option value="own">Produção própria</option><option value="third_party">Por promotora parceira</option></select></label>
     <label className={lbl}>Promotora parceira<select disabled={origin==='own'} value={provider} onChange={e=>setProvider(e.target.value)} className="field mt-1.5"><option value="">—</option>{providers.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
    </div>}
    {!!optionalQuestions.length&&<div className="rounded-[12px] border border-line p-4 text-sm">
     <strong className="text-ink">Confirme os tipos de comissão encontrados</strong>
     <div className="mt-2 grid gap-1.5">{optionalQuestions.map(([k,label])=><label key={k} className="flex items-center gap-2 text-ink-soft"><input type="checkbox" checked={answers[k]} onChange={e=>setAnswers(a=>({...a,[k]:e.target.checked}))} className="accent-[var(--brand)]" />Confirmo que o <b className="text-ink">{label}</b> desta planilha deve entrar nas tabelas.</label>)}</div>
    </div>}
    <div className="rounded-[12px] border border-line p-4">
     <label className="flex items-center gap-2 text-sm font-medium text-ink"><input type="checkbox" checked={publish} onChange={e=>setPublish(e.target.checked)} className="accent-[var(--brand)]" />Publicar já ao importar</label>
     {publish?<div className="mt-3 flex flex-wrap items-end gap-3">
      <label className={lbl}>Início da vigência<input type="date" min="2000-01-01" value={publishFrom} onChange={e=>setPublishFrom(e.target.value)} className="field mt-1.5 block w-44" /></label>
      <p className="max-w-md text-xs text-muted">{preview.validFrom?'Veio da coluna Vigência Inicial da planilha. ':''}Contratos antes dessa data não usam estas tabelas.</p>
     </div>:<p className="mt-2 text-xs text-muted">As tabelas ficam em rascunho para você conferir e publicar depois.</p>}
    </div>
    <div>{preview.issues.length>0&&<p className="mb-2 text-[13px] text-[#92400E]">Responda o que está em amarelo acima e clique em “Aplicar e ver a prévia de novo”.</p>}<button disabled={busy||preview.issues.length>0} onClick={apply} className={primary}>{busy?'Importando...':publish?`Importar e publicar ${preview.summary.tables.length} tabela(s)`:'Importar como rascunho'}</button></div>
   </div>
  </Card>}

  {message&&<div role="status" className="rounded-[12px] border border-line bg-surface p-4 text-sm text-ink">{message}{' '}{message.startsWith('Importação concluída')&&<Badge tone="received">ok</Badge>}</div>}
 </div>
}
