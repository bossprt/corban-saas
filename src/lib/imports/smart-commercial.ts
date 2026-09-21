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
export type SmartImportRepassObservation={
 group_id:string
 component_type_id:string
 raw_value:string
 rule_hint:'share_of_received'|'direct'|'unknown'
 value_kind_hint:'percentage'|'fixed_brl'|null
 source_slot:string|null
}
export type SmartGenericRepassMap=Record<string,{group_id:string;rule_hint:'share_of_received'|'direct';value_kind_hint:'percentage'|'fixed_brl'}>
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
 source_repasses:SmartImportRepassObservation[]
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
} as const
export const SMART_HEADER_ALIASES=baseAliases

export type SmartHeaderField='bank'|'agreement'|'table'|'externalCode'|'validFrom'|'validUntil'|'contract'|'term'|'termMin'|'termMax'|'coefficient'|'rate'|'factor'|'factorMode'|'factorDate'
export type SmartHeaderMap=Partial<Record<SmartHeaderField,number>>
export const SMART_HEADER_TARGETS:Record<SmartHeaderField,string>={
 bank:'Banco',agreement:'Convênio',table:'Produto / Tabela',externalCode:'Código no Banco',
 validFrom:'Vigência Inicial',validUntil:'Vigência Final',contract:'Tipo de Contrato',
 term:'Prazo',termMin:'Prazo Inicial',termMax:'Prazo Final',coefficient:'Coeficiente',
 rate:'Taxa',factor:'Fator',factorMode:'Tipo Fator',factorDate:'Data Fator',
}
const SMART_HEADER_CANONICAL:Record<SmartHeaderField,string>={
 bank:'Banco',agreement:'Convênio',table:'Produto',externalCode:'Código no Banco',
 validFrom:'Vigência Inicial',validUntil:'Vigência Final',contract:'Tipo de Contrato',
 term:'Prazo',termMin:'Prazo Inicial',termMax:'Prazo Final',coefficient:'Coeficiente',
 rate:'Taxa',factor:'Fator',factorMode:'Tipo Fator',factorDate:'Data Fator',
}
export function applySmartHeaderMap(rawRows:readonly (readonly unknown[])[],mapping:SmartHeaderMap){
 if(!Object.keys(mapping).length)return {rows:rawRows.map(r=>[...r]),issue:null as SmartImportIssue|null}
 if(!rawRows.length)return {rows:[] as unknown[][],issue:{line:1,code:'manual_mapping_invalid'} as SmartImportIssue}
 const head=[...rawRows[0]]
 const used=new Set<number>()
 for(const [keyRaw,indexRaw] of Object.entries(mapping)){
  const key=keyRaw as SmartHeaderField
  if(!(key in SMART_HEADER_CANONICAL)||!Number.isInteger(indexRaw)||indexRaw<0||indexRaw>=head.length||used.has(indexRaw)){
   return {rows:[] as unknown[][],issue:{line:1,code:'manual_mapping_invalid'} as SmartImportIssue}
  }
  used.add(indexRaw)
  head[indexRaw]=SMART_HEADER_CANONICAL[key]
 }
 return {rows:[head,...rawRows.slice(1).map(r=>[...r])],issue:null as SmartImportIssue|null}
}

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
const resolveType=(raw:string,types:readonly SmartImportContractType[],valueMap:Record<string,string>={})=>{
 const mapped=valueMap[raw.trim()]
 if(mapped)return types.find(t=>t.id===mapped)??null
 const k=n(raw)
 return types.find(t=>n(t.name)===k||n(t.tech_key)===k)??null
}
const componentFromHeader=(header:string,components:readonly SmartImportComponent[])=>{
 const h=n(header)
 const company=!/(repasse|corretor|parceiro|balcao|indicador|afiliado)/.test(h)||/empresa/.test(h)
 if(!company)return null
 for(const c of components){
  const aliases=componentAliases[c.tech_key]??[n(c.name)]
  if(aliases.some(a=>h===a||h.startsWith(a+'_')||h.includes('_'+a+'_')||h.includes(a+'_empresa')))return c
 }
 return null
}
const unitFor=(header:string,unitRaw:string,componentKey:string):'percentage'|'fixed_brl'|null=>{
 const u=n(unitRaw),h=n(header)
 if(/(^|_)r(_|$)|reais|brl/.test(u)||/r\$/.test(unitRaw)||h.includes('valor_fixo')||h.includes('seguro_fixo'))return 'fixed_brl'
 if(u==='%'||u==='percentual'||u==='porcentagem'||u==='percent'||h.includes('percent'))return 'percentage'
 if(['upfront','deferred','bonus_1','bonus_2','bonus_3'].includes(componentKey))return 'percentage'
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
 ctx:{contractTypes:readonly SmartImportContractType[];groups:readonly SmartImportGroup[];components:readonly SmartImportComponent[];contractTypeValueMap?:Record<string,string>;genericRepassMap?:SmartGenericRepassMap}
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
 const commissionBaseCol=firstIndex(head,['base_da_comissao','base_calculo','base_calculo_a_vista','base_de_calculo'])
 const col={
  bank:firstIndex(head,baseAliases.bank),agreement:firstIndex(head,baseAliases.agreement),table:firstIndex(head,baseAliases.table),
  externalCode:firstIndex(head,baseAliases.externalCode),validFrom:firstIndex(head,baseAliases.validFrom),validUntil:firstIndex(head,baseAliases.validUntil),
  contract:firstIndex(head,baseAliases.contract),term:firstIndex(head,baseAliases.term),termMin:firstIndex(head,baseAliases.termMin),termMax:firstIndex(head,baseAliases.termMax),
  coefficient:firstIndex(head,baseAliases.coefficient),rate:firstIndex(head,baseAliases.rate),factor:firstIndex(head,baseAliases.factor),
  factorMode:firstIndex(head,baseAliases.factorMode),factorDate:firstIndex(head,baseAliases.factorDate),
 }
 for(const [k,v] of Object.entries({bank:col.bank,agreement:col.agreement,table:col.table,contract:col.contract}))if(v===undefined)issues.push({line:1,code:`missing_${k}`})
 if(col.term===undefined&&col.termMin===undefined)issues.push({line:1,code:'missing_term'})
 if(col.coefficient===undefined&&col.rate===undefined&&col.factor===undefined)issues.push({line:1,code:'missing_rate_coefficient_or_factor'})

 const componentCols:{value:number;unit?:number;component:SmartImportComponent;header:string}[]=[]
 for(let i=0;i<rawHead.length;i++){
  const c=componentFromHeader(rawHead[i],ctx.components)
  if(!c)continue
  if(/unidade/.test(head[i]))continue
  const unit=head.findIndex((h,j)=>j!==i&&h.includes(n(c.name))&&h.includes('empresa')&&h.includes('unidade'))
  componentCols.push({value:i,unit:unit>=0?unit:undefined,component:c,header:rawHead[i]})
 }

 const genericRepasseSlotIds=[...new Set(rawHead.map(h=>/repasse[_ ]?(\d+)/i.exec(n(h))?.[1]).filter((x):x is string=>!!x))]
 const genericRepasseSlots=genericRepasseSlotIds.map(x=>`Repasse ${x}`)
 const genericRepasse=genericRepasseSlots.length>0
 const mappedGeneric=new Set(Object.keys(ctx.genericRepassMap??{}))
 const missingGeneric=genericRepasseSlotIds.filter(x=>!mappedGeneric.has(x))
 if(missingGeneric.length)issues.push({line:1,code:'generic_repass_requires_mapping',detail:`${missingGeneric.map(x=>`Repasse ${x}`).join(', ')} ainda não está vinculado a um Grupo de Comissão.`})
 const genericRepassCols:{value:number;slot:string;component:SmartImportComponent}[]=[]
 for(let i=0;i<rawHead.length;i++){
  const slot=/repasse[_ ]?(\d+)/i.exec(n(rawHead[i]))?.[1]
  if(!slot)continue
  const component=ctx.components.find(c=>(componentAliases[c.tech_key]??[n(c.name)]).some(a=>head[i].includes(a)))
  if(component)genericRepassCols.push({value:i,slot,component})
 }

 const namedRepassCols:{value:number;group:SmartImportGroup;component:SmartImportComponent;header:string}[]=[]
 for(let i=0;i<rawHead.length;i++){
  const h=head[i]
  const group=ctx.groups.find(g=>h.includes(n(g.name)))
  if(!group)continue
  const component=ctx.components.find(c=>(componentAliases[c.tech_key]??[n(c.name)]).some(a=>h.includes(a)))
  if(component)namedRepassCols.push({value:i,group,component,header:rawHead[i]})
 }

 const consumed=new Set<number>([...Object.values(col).filter((v):v is number=>v!==undefined),...(commissionBaseCol===undefined?[]:[commissionBaseCol]),...componentCols.flatMap(c=>[c.value,...(c.unit===undefined?[]:[c.unit])]),...namedRepassCols.map(c=>c.value),...genericRepassCols.map(c=>c.value)])
 for(let i=0;i<rawHead.length;i++){
  const h=head[i]
  if(!h||consumed.has(i)||/repasse[_ ]?\d+/.test(h)||/unidade/.test(h)||IGNORABLE.test(h))continue
  if(MONEY_WORDS.test(h))issues.push({line:1,code:'unrecognized_commission_column',detail:rawHead[i].slice(0,60)})
 }
 if(issues.some(x=>x.line===1&&x.code!=='generic_repass_requires_mapping')){
  return {rows:[],issues,summary:{sourceRows,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:genericRepasse,genericRepasseSlots}}
 }

 rawRows.slice(1).forEach((r,idx)=>{
  const line=idx+2
  const bank=cell(r,col.bank),agreement=cell(r,col.agreement),table=cell(r,col.table),contractRaw=cell(r,col.contract)
  if(!bank||!agreement||!table||!contractRaw){issues.push({line,code:'missing_identity'});return}
  const type=resolveType(contractRaw,ctx.contractTypes,ctx.contractTypeValueMap)
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

  const baseRaw=commissionBaseCol===undefined?'':cell(r,commissionBaseCol)
  const baseNorm=n(baseRaw)
  const commissionBase=baseRaw===''?null:baseNorm==='liquido'?'LÍQUIDO':baseNorm==='bruto'?'BRUTO':null
  if(baseRaw!==''&&!commissionBase){issues.push({line,code:'invalid_commission_base',detail:baseRaw});return}

  const comps:SmartImportComponentValue[]=[]
  for(const cc of componentCols){
   const raw=cell(r,cc.value)
   if(raw==='')continue
   const value=decimal(raw,9,8)
   if(value===null){issues.push({line,code:'invalid_component_value',detail:cc.component.name});return}
   if(Number(value)===0)continue
   const unit=unitFor(cc.header,cc.unit===undefined?'':cell(r,cc.unit),cc.component.tech_key)
   if(!unit){issues.push({line,code:'component_unit_required',detail:cc.component.name});return}
   if(unit==='percentage'&&Number(value)>100){issues.push({line,code:'component_percentage_over_100',detail:cc.component.name});return}
   comps.push({component_type_id:cc.component.id,value_kind:unit,received_value:value,source:'import',calculation_base:commissionBase})
  }

  const repasses:SmartImportRepassObservation[]=[]
  for(const rc of namedRepassCols){
   const raw=cell(r,rc.value)
   if(raw==='')continue
   const value=decimal(raw,9,8)
   if(value===null){issues.push({line,code:'invalid_repass_value',detail:`${rc.group.name} / ${rc.component.name}`});return}
   repasses.push({group_id:rc.group.id,component_type_id:rc.component.id,raw_value:value,rule_hint:'unknown',value_kind_hint:null,source_slot:null})
  }

  for(const gc of genericRepassCols){
   const mapping=ctx.genericRepassMap?.[gc.slot]
   if(!mapping)continue
   const group=ctx.groups.find(g=>g.id===mapping.group_id)
   if(!group){issues.push({line,code:'generic_repass_mapping_invalid',detail:`Repasse ${gc.slot}`});return}
   const raw=cell(r,gc.value)
   if(raw==='')continue
   const value=decimal(raw,9,8)
   if(value===null){issues.push({line,code:'invalid_repass_value',detail:`Repasse ${gc.slot} / ${gc.component.name}`});return}
   repasses.push({group_id:group.id,component_type_id:gc.component.id,raw_value:value,rule_hint:mapping.rule_hint,value_kind_hint:mapping.value_kind_hint,source_slot:gc.slot})
  }

  if(rows.length+(max-min+1)>SMART_LIMITS.expandedRows){issues.push({line,code:'file_too_large_for_import'});return}
  for(let term=min;term<=max;term++)rows.push({
   bank_name:bank,agreement_name:agreement,table_name:table,external_table_code:cell(r,col.externalCode)||null,
   contract_type_id:type.id,contract_type_name:type.name,term,
   coefficient:coefficient??factor,rate,effective_from:from,effective_until:until,
   factor_mode:fMode,factor_value:factor,factor_date:fDate,
   components:comps,source_repasses:repasses,
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
   hasGenericRepasseColumns:genericRepasse,genericRepasseSlots,
  }
 }
}
