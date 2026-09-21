import { normalizeHeader, parseCoefficient, parseRate, parseTerm, parseDecimal } from '../commercial'

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
}
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
 }
}

const baseAliases={
 bank:['banco','instituicao','banco_instituicao'],
 agreement:['convenio'],
 table:['produto','tabela','produto_tabela','nome_do_produto','nome_tabela'],
 externalCode:['codigo_no_banco','codigo_banco','codigo_tabela','cod_tabela'],
 validFrom:['vigencia','vigencia_inicial','inicio_vigencia'],
 validUntil:['vigencia_final','fim_vigencia'],
 contract:['tipo_de_contrato','tipo_contrato','contrato'],
 term:['prazo'],
 termMin:['prazo_inicial','prazo_minimo','prazo_min'],
 termMax:['prazo_final','prazo_maximo','prazo_max'],
 coefficient:['coeficiente'],
 rate:['taxa','taxa_a_m','taxa_am','taxa_mensal'],
 factor:['fator'],
 factorMode:['tipo_fator','tipo_de_fator'],
 factorDate:['data_fator','vigencia_fator'],
} as const

const componentAliases:Record<string,string[]>={
 upfront:['a_vista','avista','comissao_a_vista'],
 deferred:['diferido','comissao_diferida'],
 bonus_1:['bonus','bonus_1'],
 bonus_2:['bonus_2','bonus_2_percent'],
 bonus_3:['bonus_3','bonus_3_percent'],
 plastic:['plastico','cartao_plastico'],
 insurance_fixed:['seguro_fixo','seguro'],
}

const n=(v:unknown)=>normalizeHeader(v)
const cell=(row:readonly unknown[],i:number|undefined)=>i===undefined?'':String(row[i]??'').trim()
const firstIndex=(head:string[],aliases:readonly string[])=>{
 for(const a of aliases){const i=head.indexOf(a);if(i>=0)return i}
 return undefined
}
const parseDate=(raw:string):string|null=>{
 const v=raw.trim()
 if(!v)return null
 const iso=/^(\d{4})-(\d{2})-(\d{2})/.exec(v)
 if(iso)return `${iso[1]}-${iso[2]}-${iso[3]}T00:00:00Z`
 const br=/^(\d{1,2})\/(\d{1,2})\/(\d{4})/.exec(v)
 if(br)return `${br[3]}-${br[2].padStart(2,'0')}-${br[1].padStart(2,'0')}T00:00:00Z`
 return null
}
const decimal=(raw:string,maxInt=6,scale=8)=>parseDecimal(raw,{maxInt,scale})
const positiveDecimal=(raw:string,maxInt=6,scale=8)=>{
 const d=decimal(raw,maxInt,scale)
 return d!==null&&Number(d)>0?d:null
}
const resolveType=(raw:string,types:readonly SmartImportContractType[])=>{
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
 ctx:{contractTypes:readonly SmartImportContractType[];groups:readonly SmartImportGroup[];components:readonly SmartImportComponent[]}
):SmartImportResult{
 const issues:SmartImportIssue[]=[]
 const rows:SmartImportRow[]=[]
 const sourceRows=Math.max(0,rawRows.length-1)
 if(rawRows.length<2){
  return {rows:[],issues:[{line:1,code:'file_without_rows'}],summary:{sourceRows:0,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false}}
 }
 const rawHead=rawRows[0].map(x=>String(x??'').trim())
 const head=rawHead.map(n)
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

 const genericRepasse=rawHead.some(h=>/repasse[_ ]?\d+/i.test(n(h)))
 if(genericRepasse)issues.push({line:1,code:'generic_repass_requires_mapping',detail:'Repasse 1/2/3 não identifica Corretor, Parceiro ou outro grupo.'})

 const namedRepassCols:{value:number;group:SmartImportGroup;component:SmartImportComponent;header:string}[]=[]
 for(let i=0;i<rawHead.length;i++){
  const h=head[i]
  const group=ctx.groups.find(g=>h.includes(n(g.name)))
  if(!group)continue
  const component=ctx.components.find(c=>(componentAliases[c.tech_key]??[n(c.name)]).some(a=>h.includes(a)))
  if(component)namedRepassCols.push({value:i,group,component,header:rawHead[i]})
 }

 if(issues.some(x=>x.line===1&&x.code!=='generic_repass_requires_mapping')){
  return {rows:[],issues,summary:{sourceRows,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:genericRepasse}}
 }

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
  const factor=col.factor===undefined||cell(r,col.factor)===''?null:positiveDecimal(cell(r,col.factor),6,12)
  if((col.coefficient!==undefined&&cell(r,col.coefficient)!==''&&coefficient===null)||(col.rate!==undefined&&cell(r,col.rate)!==''&&rate===null)||(col.factor!==undefined&&cell(r,col.factor)!==''&&factor===null)){
   issues.push({line,code:'invalid_number'});return
  }
  if(coefficient===null&&rate===null&&factor===null){issues.push({line,code:'rate_coefficient_or_factor_required'});return}
  const from=col.validFrom===undefined?null:parseDate(cell(r,col.validFrom))
  const until=col.validUntil===undefined?null:parseDate(cell(r,col.validUntil))
  if((col.validFrom!==undefined&&cell(r,col.validFrom)!==''&&!from)||(col.validUntil!==undefined&&cell(r,col.validUntil)!==''&&!until)){issues.push({line,code:'invalid_date'});return}
  const fMode=factor===null?null:(col.factorMode===undefined?'daily':factorMode(cell(r,col.factorMode)))
  if(factor!==null&&!fMode){issues.push({line,code:'factor_mode_required'});return}
  const fDateRaw=col.factorDate===undefined?'':cell(r,col.factorDate)
  const fDate=(fDateRaw?parseDate(fDateRaw):from)?.slice(0,10)??null

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
   comps.push({component_type_id:cc.component.id,value_kind:unit,received_value:value,source:'import'})
  }

  const repasses:SmartImportRepassObservation[]=[]
  for(const rc of namedRepassCols){
   const raw=cell(r,rc.value)
   if(raw==='')continue
   const value=decimal(raw,9,8)
   if(value===null){issues.push({line,code:'invalid_repass_value',detail:`${rc.group.name} / ${rc.component.name}`});return}
   repasses.push({group_id:rc.group.id,component_type_id:rc.component.id,raw_value:value,rule_hint:'unknown',value_kind_hint:null})
  }

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
   hasGenericRepasseColumns:genericRepasse,
  }
 }
}
