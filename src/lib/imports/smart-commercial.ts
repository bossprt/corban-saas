import { normalizeHeader, parseTerm, parseDecimal } from '../commercial'

export type SmartImportContractType={id:string;name:string;tech_key:string}
export type SmartImportGroup={id:string;name:string}
export type SmartImportComponent={id:string;tech_key:string;name:string}
export type SmartImportIssue={line:number;code:string;detail?:string}
export type SmartImportComponentValue={
 component_type_id:string
 value_kind:'percentage'|'fixed_brl'
 received_value:string
 source:'import'
 calculation_base?:string|null
}
// What a seller group gets for one commission type on one line (part B, ADR-0036): % of the operation or a fixed R$.
export type SmartImportGroupValue={
 group_id:string
 component_type_id:string
 value_kind:'percentage'|'fixed_brl'
 value:string
 source:'import'
}
// "Repasse N" columns (2tech layout) are mapped to a group by the person importing: slot number -> group id, or null to ignore.
export type RepassMap=Record<string,string|null>
export type SmartImportRow={
 bank_name:string
 agreement_name:string
 table_name:string
 external_table_code:string|null
 contract_type_id:string
 contract_type_name:string
 term:number
 coefficient:string|null
 rate:string|null
 effective_from:string|null
 effective_until:string|null
 factor_mode:'daily'|'fixed'|null
 factor_value:string|null
 factor_date:string|null
 components:SmartImportComponentValue[]
 group_values:SmartImportGroupValue[]
 // Imposto (%) of the line; only present when the file has the column (empty cell = 0 = no tax).
 tax_pct?:string
}
export type SmartImportResult={
 rows:SmartImportRow[]
 issues:SmartImportIssue[]
 summary:{
  sourceRows:number
  expandedRows:number
  tables:string[]
  components:string[]
  hasDeferred:boolean
  hasPlastic:boolean
  hasBonus:boolean
  hasGenericRepasseColumns:boolean
  genericRepasseSlots:string[]
  hasUnmappedRepassValues?:boolean
  groups?:string[]
 }
}

export const SMART_LIMITS={sourceRows:5000,expandedRows:20000,columns:200,text:200} as const
const baseAliases={
 bank:['banco','instituicao','banco_instituicao'],
 agreement:['convenio'],
 table:['produto','tabela','produto_tabela','nome_do_produto','nome_tabela','tabela_nome_do_produto','tabela_produto'],
 externalCode:['codigo_no_banco','codigo_banco','codigo_tabela','cod_tabela'],
 validFrom:['vigencia','vigencia_inicial','inicio_vigencia','inicio','data_inicio_vigencia','data_inicial_vigencia'],
 validUntil:['vigencia_final','fim_vigencia','fim','data_final_vigencia','data_fim_vigencia'],
 contract:['tipo_de_contrato','tipo_contrato','contrato'],
 term:['prazo'],
 termMin:['prazo_inicial','prazo_minimo','prazo_min'],
 termMax:['prazo_final','prazo_maximo','prazo_max'],
 coefficient:['coeficiente'],
 rate:['taxa','taxa_a_m','taxa_am','taxa_mensal'],
 factor:['fator'],
 factorMode:['tipo_fator','tipo_de_fator'],
 factorDate:['data_fator','vigencia_fator','data_do_fator','data_referencia','data'],
 tax:['imposto','imposto_percentual','percentual_imposto','aliquota_imposto','aliquota'],
 base:['base_de_calculo','base_calculo','base_calculo_comissao','base'],
} as const
export const SMART_HEADER_ALIASES=baseAliases

const componentAliases:Record<string,string[]>={
 upfront:['a_vista','avista','comissao_a_vista'],
 deferred:['diferido','comissao_diferida'],
 bonus_1:['bonus','bonus_1'],
 bonus_2:['bonus_2','bonus_2_percent'],
 bonus_3:['bonus_3','bonus_3_percent'],
 plastic:['plastico','cartao_plastico'],
 insurance_fixed:['seguro_fixo','seguro'],
}

// Columns that carry money but are not understood are REFUSED (silently dropping a commission column would be a financial error). Known harmless ones are listed.
const MONEY_WORDS=/(comiss|bonus|repasse|diferido|a_vista|avista|plastico|seguro|spread|premio)/
const IGNORABLE=/^(base_calculo|id_|idade|valor_contrato|taxa_inicial|taxa_final|tipo_de_formalizacao|ativacao)/
const n=(v:unknown)=>normalizeHeader(v)
const cell=(row:readonly unknown[],i:number|undefined)=>i===undefined?'':String(row[i]??'').trim()
const firstIndex=(head:string[],aliases:readonly string[])=>{
 for(const a of aliases){const i=head.indexOf(a);if(i>=0)return i}
 return undefined
}
// open-ended validity written as text (HOPE exports "Não definida"): only for the END date, it means "no end" and is not an error
const OPEN_END=/^(nao definida|não definida|indefinida|indeterminada|sem fim|sem data|-|—)$/i
// a real calendar date only (32/13/2026 or 2026-02-30 are refused, never stored)
const validYmd=(y:number,m:number,d:number)=>m>=1&&m<=12&&d>=1&&d<=new Date(Date.UTC(y,m,0)).getUTCDate()&&y>=1990&&y<=2100
const parseDate=(raw:string):string|null=>{
 const v=raw.trim()
 if(!v)return null
 const iso=/^(\d{4})-(\d{2})-(\d{2})/.exec(v)
 if(iso)return validYmd(+iso[1],+iso[2],+iso[3])?`${iso[1]}-${iso[2]}-${iso[3]}T00:00:00Z`:null
 const br=/^(\d{1,2})\/(\d{1,2})\/(\d{4})/.exec(v)
 if(br)return validYmd(+br[3],+br[2],+br[1])?`${br[3]}-${br[2].padStart(2,'0')}-${br[1].padStart(2,'0')}T00:00:00Z`:null
 return null
}
const decimal=(raw:string,maxInt=6,scale=8)=>parseDecimal(raw,{maxInt,scale})
// a factor of 0 means "no factor informed" (HOPE exports DIÁRIO with Fator 0): it is not an error and not a factor; a malformed or negative one is still refused
const factorDecimal=(raw:string,maxInt=6,scale=12):string|null|'zero'=>{
 const d=decimal(raw,maxInt,scale)
 if(d===null)return null
 return Number(d)===0?'zero':d
}
const resolveType=(raw:string,types:readonly SmartImportContractType[])=>{
 const k=n(raw)
 return types.find(t=>n(t.name)===k||n(t.tech_key)===k)??null
}
// Every commission column is "<type>" or "<type> (<who>)": who is Empresa, a registered seller group, or Repasse N.
// Anything else in the parenthesis is an unknown group and the file is refused (money is never read by guess).
type HeaderClass=
 |{kind:'company';component:SmartImportComponent}
 |{kind:'group';component:SmartImportComponent;group:SmartImportGroup}
 |{kind:'slot';component:SmartImportComponent;slot:string}
 |{kind:'unknown';component:SmartImportComponent}
const classifyHeader=(header:string,components:readonly SmartImportComponent[],groups:readonly SmartImportGroup[]):HeaderClass|null=>{
 const h=n(header)
 if(!h||/unidade/.test(h))return null
 const aliases=components.flatMap(c=>[...(componentAliases[c.tech_key]??[]),n(c.name)].map(a=>({a,c}))).sort((x,y)=>y.a.length-x.a.length)
 for(const {a,c} of aliases){
  if(h===a)return {kind:'company',component:c}
  if(!h.startsWith(a+'_'))continue
  const rest=h.slice(a.length+1).replace(/_valor$/,'')
  if(rest==='empresa')return {kind:'company',component:c}
  const group=groups.find(g=>n(g.name)===rest)
  if(group)return {kind:'group',component:c,group}
  const slot=/^repasse_(\d+)$/.exec(rest)
  if(slot)return {kind:'slot',component:c,slot:slot[1]}
  return {kind:'unknown',component:c}
 }
 return null
}
// Number = % of the operation; "R$ 25,00" = fixed amount (owner decision). A separate unit column still wins when present.
const moneyValue=(raw:string):{value:string|null;fixed:boolean}=>{
 const fixed=/r\$/i.test(raw)
 let t=raw.replace(/r\$/i,'').replace(/\s+/g,'')
 if(fixed&&t.includes(','))t=t.replace(/\./g,'')
 return {value:decimal(t,9,8),fixed}
}
const unitFor=(header:string,unitRaw:string,fixedInValue:boolean):'percentage'|'fixed_brl'=>{
 const u=n(unitRaw),h=n(header)
 if(fixedInValue||/(^|_)r(_|$)|reais|brl/.test(u)||/r\$/.test(unitRaw)||h.includes('valor_fixo'))return 'fixed_brl'
 return 'percentage'
}
export type CalculationBase='BRUTO'|'LÍQUIDO'
// "Bruto", "B", "Líquido", "L" (2tech shows the base as B/L); anything else is refused.
export const parseCalculationBase=(raw:string):CalculationBase|null=>{
 const k=n(raw)
 if(k==='b'||k.startsWith('bruto'))return 'BRUTO'
 if(k==='l'||k.startsWith('liquido'))return 'LÍQUIDO'
 return null
}
const factorMode=(raw:string):'daily'|'fixed'|null=>{
 const k=n(raw)
 if(k.includes('diario'))return 'daily'
 if(k.includes('fixo'))return 'fixed'
 return null
}

export function mapSmartCommercialRows(
 rawRows:readonly (readonly unknown[])[],
 ctx:{contractTypes:readonly SmartImportContractType[];groups:readonly SmartImportGroup[];components:readonly SmartImportComponent[];repassMap?:RepassMap;defaultBase?:CalculationBase}
):SmartImportResult{
 const issues:SmartImportIssue[]=[]
 const rows:SmartImportRow[]=[]
 const sourceRows=Math.max(0,rawRows.length-1)
 if(rawRows.length<2){
  return {rows:[],issues:[{line:1,code:'file_without_rows'}],summary:{sourceRows:0,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false,genericRepasseSlots:[]}}
 }
 if(rawRows.length-1>SMART_LIMITS.sourceRows||rawRows[0].length>SMART_LIMITS.columns){
  return {rows:[],issues:[{line:1,code:'file_too_large_for_import'}],summary:{sourceRows,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false,genericRepasseSlots:[]}}
 }
 const rawHead=rawRows[0].map(x=>String(x??'').trim())
 const head=rawHead.map(n)
 const col={
  bank:firstIndex(head,baseAliases.bank),agreement:firstIndex(head,baseAliases.agreement),table:firstIndex(head,baseAliases.table),
  externalCode:firstIndex(head,baseAliases.externalCode),validFrom:firstIndex(head,baseAliases.validFrom),validUntil:firstIndex(head,baseAliases.validUntil),
  contract:firstIndex(head,baseAliases.contract),term:firstIndex(head,baseAliases.term),termMin:firstIndex(head,baseAliases.termMin),termMax:firstIndex(head,baseAliases.termMax),
  coefficient:firstIndex(head,baseAliases.coefficient),rate:firstIndex(head,baseAliases.rate),factor:firstIndex(head,baseAliases.factor),
  factorMode:firstIndex(head,baseAliases.factorMode),factorDate:firstIndex(head,baseAliases.factorDate),
  tax:firstIndex(head,baseAliases.tax),base:firstIndex(head,baseAliases.base),
 }
 for(const [k,v] of Object.entries({bank:col.bank,agreement:col.agreement,table:col.table,contract:col.contract}))if(v===undefined)issues.push({line:1,code:`missing_${k}`})
 if(col.term===undefined&&col.termMin===undefined)issues.push({line:1,code:'missing_term'})
 if(col.coefficient===undefined&&col.rate===undefined&&col.factor===undefined)issues.push({line:1,code:'missing_rate_coefficient_or_factor'})

 const componentCols:{value:number;unit?:number;component:SmartImportComponent;header:string}[]=[]
 const groupCols:{value:number;group:SmartImportGroup;component:SmartImportComponent;header:string}[]=[]
 const slotCols:{value:number;slot:string;component:SmartImportComponent;header:string}[]=[]
 for(let i=0;i<rawHead.length;i++){
  const c=classifyHeader(rawHead[i],ctx.components,ctx.groups)
  if(!c)continue
  if(c.kind==='company'){
   const unit=head.findIndex((h,j)=>j!==i&&h.includes(n(c.component.name))&&h.includes('empresa')&&h.includes('unidade'))
   componentCols.push({value:i,unit:unit>=0?unit:undefined,component:c.component,header:rawHead[i]})
  }else if(c.kind==='group')groupCols.push({value:i,group:c.group,component:c.component,header:rawHead[i]})
  else if(c.kind==='slot')slotCols.push({value:i,slot:c.slot,component:c.component,header:rawHead[i]})
  else issues.push({line:1,code:'unknown_group_column',detail:rawHead[i].slice(0,60)})
 }

 // Repasse N: each slot must be mapped to a group (or explicitly ignored) by the person importing.
 const repassMap=ctx.repassMap??{}
 const genericRepasseSlots=[...new Set(slotCols.map(c=>c.slot))].sort((a,b)=>+a-+b).map(x=>`Repasse ${x}`)
 const genericRepasse=genericRepasseSlots.length>0
 const unmapped=[...new Set(slotCols.map(c=>c.slot))].filter(x=>!Object.prototype.hasOwnProperty.call(repassMap,x))
 if(unmapped.length)issues.push({line:1,code:'generic_repass_requires_mapping',detail:unmapped.map(x=>`Repasse ${x}`).join(', ')})
 for(const [slot,groupId] of Object.entries(repassMap)){
  if(groupId===null)continue
  const group=ctx.groups.find(g=>g.id===groupId)
  if(!group){issues.push({line:1,code:'repass_map_invalid_group',detail:`Repasse ${slot}`});continue}
  for(const sc of slotCols.filter(x=>x.slot===slot))groupCols.push({value:sc.value,group,component:sc.component,header:sc.header})
 }
 const seenPair=new Set<string>()
 for(const g of groupCols){
  const k=`${g.group.id}:${g.component.id}`
  if(seenPair.has(k))issues.push({line:1,code:'duplicate_group_column',detail:g.header.slice(0,60)})
  seenPair.add(k)
 }

 const consumed=new Set<number>([...Object.values(col).filter((v):v is number=>v!==undefined),...componentCols.flatMap(c=>[c.value,...(c.unit===undefined?[]:[c.unit])]),...groupCols.map(c=>c.value),...slotCols.map(c=>c.value)])
 for(let i=0;i<rawHead.length;i++){
  const h=head[i]
  if(!h||consumed.has(i)||/unidade/.test(h)||IGNORABLE.test(h))continue
  if(MONEY_WORDS.test(h))issues.push({line:1,code:'unrecognized_commission_column',detail:rawHead[i].slice(0,60)})
 }
 // The base (gross or net amount) decides the money: a file without it needs the person importing to choose one.
 if(col.base===undefined&&!ctx.defaultBase)issues.push({line:1,code:'calculation_base_required'})
 if(issues.some(x=>x.line===1&&x.code!=='generic_repass_requires_mapping'&&x.code!=='calculation_base_required')){
  return {rows:[],issues,summary:{sourceRows,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:genericRepasse,genericRepasseSlots}}
 }

 let hasUnmappedValue=false
 rawRows.slice(1).forEach((r,idx)=>{
  const line=idx+2
  const bank=cell(r,col.bank),agreement=cell(r,col.agreement),table=cell(r,col.table),contractRaw=cell(r,col.contract)
  if(!bank||!agreement||!table||!contractRaw){issues.push({line,code:'missing_identity'});return}
  const type=resolveType(contractRaw,ctx.contractTypes)
  if(!type){issues.push({line,code:'unknown_contract_type',detail:contractRaw});return}
  const single=col.term===undefined?null:parseTerm(cell(r,col.term))
  const min=single??(col.termMin===undefined?null:parseTerm(cell(r,col.termMin)))
  const max=single??(col.termMax===undefined?min:parseTerm(cell(r,col.termMax)))
  if(min===null||max===null||max<min||max-min>240){issues.push({line,code:'invalid_term_range'});return}
  const coefficient=col.coefficient===undefined||cell(r,col.coefficient)===''?null:decimal(cell(r,col.coefficient),6,8)
  const rate=col.rate===undefined||cell(r,col.rate)===''?null:decimal(cell(r,col.rate),3,6)
  const factorRaw=col.factor===undefined||cell(r,col.factor)===''?null:factorDecimal(cell(r,col.factor),6,12)
  const factor=factorRaw==='zero'?null:factorRaw
  if((col.coefficient!==undefined&&cell(r,col.coefficient)!==''&&coefficient===null)||(col.rate!==undefined&&cell(r,col.rate)!==''&&rate===null)||(col.factor!==undefined&&cell(r,col.factor)!==''&&factorRaw===null)){
   issues.push({line,code:'invalid_number'});return
  }
  if(coefficient===null&&rate===null&&factor===null){issues.push({line,code:'rate_coefficient_or_factor_required'});return}
  const from=col.validFrom===undefined?null:parseDate(cell(r,col.validFrom))
  const untilRaw=col.validUntil===undefined?'':cell(r,col.validUntil),openEnd=OPEN_END.test(untilRaw)
  const until=col.validUntil===undefined||openEnd?null:parseDate(untilRaw)
  if((col.validFrom!==undefined&&cell(r,col.validFrom)!==''&&!from)||(col.validUntil!==undefined&&untilRaw!==''&&!openEnd&&!until)){issues.push({line,code:'invalid_date'});return}
  const fMode=factor===null?null:(col.factorMode===undefined?'daily':factorMode(cell(r,col.factorMode)))
  if(factor!==null&&!fMode){issues.push({line,code:'factor_mode_required'});return}
  const fDateRaw=col.factorDate===undefined?'':cell(r,col.factorDate)
  const fDate=(fDateRaw?parseDate(fDateRaw):from)?.slice(0,10)??null
  if(fDateRaw&&!parseDate(fDateRaw)){issues.push({line,code:'invalid_date'});return}
  if(factor!==null&&fMode==='daily'&&!fDate){issues.push({line,code:'factor_date_required'});return}
  if([bank,agreement,table].some(x=>x.length>SMART_LIMITS.text)){issues.push({line,code:'text_too_long'});return}
  const taxRaw=col.tax===undefined?'':cell(r,col.tax).replace(/%$/,'').trim()
  const tax=col.tax===undefined?undefined:taxRaw===''?'0':decimal(taxRaw,3,6)
  if(tax===null||(tax!==undefined&&Number(tax)>100)){issues.push({line,code:'invalid_tax'});return}
  const baseRaw=col.base===undefined?'':cell(r,col.base)
  const rowBase=baseRaw?parseCalculationBase(baseRaw):ctx.defaultBase??null
  if(baseRaw&&!rowBase){issues.push({line,code:'invalid_calculation_base',detail:baseRaw.slice(0,20)});return}
  if(!rowBase&&col.base!==undefined){issues.push({line,code:'missing_calculation_base'});return}

  const comps:SmartImportComponentValue[]=[]
  for(const cc of componentCols){
   const raw=cell(r,cc.value)
   if(raw==='')continue
   const {value,fixed}=moneyValue(raw)
   if(value===null){issues.push({line,code:'invalid_component_value',detail:cc.component.name});return}
   if(Number(value)===0)continue
   const unit=unitFor(cc.header,cc.unit===undefined?'':cell(r,cc.unit),fixed)
   if(unit==='percentage'&&Number(value)>100){issues.push({line,code:'component_percentage_over_100',detail:cc.component.name});return}
   comps.push({component_type_id:cc.component.id,value_kind:unit,received_value:value,source:'import',calculation_base:rowBase})
  }

  // Empty or zero = the type does not apply to the group on this line.
  const groupValues:SmartImportGroupValue[]=[]
  for(const gc of groupCols){
   const raw=cell(r,gc.value)
   if(raw==='')continue
   const {value,fixed}=moneyValue(raw)
   if(value===null){issues.push({line,code:'invalid_repass_value',detail:`${gc.group.name} / ${gc.component.name}`});return}
   if(Number(value)===0)continue
   if(!fixed&&Number(value)>100){issues.push({line,code:'invalid_repass_value',detail:`${gc.group.name} / ${gc.component.name}`});return}
   groupValues.push({group_id:gc.group.id,component_type_id:gc.component.id,value_kind:fixed?'fixed_brl':'percentage',value,source:'import'})
  }
  // A mapped slot with values but no answer yet blocks the line (never silently dropped).
  for(const sc of slotCols){
   if(Object.prototype.hasOwnProperty.call(repassMap,sc.slot))continue
   const raw=cell(r,sc.value)
   if(raw!==''&&moneyValue(raw).value!==null&&Number(moneyValue(raw).value)!==0){hasUnmappedValue=true;break}
  }

  if(rows.length+(max-min+1)>SMART_LIMITS.expandedRows){issues.push({line,code:'file_too_large_for_import'});return}
  for(let term=min;term<=max;term++)rows.push({
   bank_name:bank,agreement_name:agreement,table_name:table,external_table_code:cell(r,col.externalCode)||null,
   contract_type_id:type.id,contract_type_name:type.name,term,
   coefficient:coefficient??factor,rate,effective_from:from,effective_until:until,
   factor_mode:fMode,factor_value:factor,factor_date:fDate,
   components:comps,group_values:groupValues,
   ...(tax===undefined?{}:{tax_pct:tax}),
  })
 })

 const componentNames=new Set<string>()
 for(const row of rows)for(const c of row.components){const ref=ctx.components.find(x=>x.id===c.component_type_id);if(ref)componentNames.add(ref.tech_key)}
 const tables=[...new Set(rows.map(r=>`${r.bank_name} · ${r.agreement_name} · ${r.table_name}`))]
 return {
  rows:issues.some(i=>i.line>1)?[]:rows,
  issues,
  summary:{
   sourceRows,expandedRows:rows.length,tables,components:[...componentNames],
   hasDeferred:componentNames.has('deferred'),hasPlastic:componentNames.has('plastic'),
   hasBonus:['bonus_1','bonus_2','bonus_3'].some(x=>componentNames.has(x)),
   hasGenericRepasseColumns:genericRepasse,genericRepasseSlots,hasUnmappedRepassValues:hasUnmappedValue,
   groups:[...new Set(rows.flatMap(r=>r.group_values.map(v=>v.group_id)))].map(id=>ctx.groups.find(g=>g.id===id)?.name??id),
  }
 }
}
