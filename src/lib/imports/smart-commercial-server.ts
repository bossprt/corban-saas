
import { readSmartFile, type SmartFormat } from '@/lib/imports/smart-file'
import { normalizeHeader } from '@/lib/commercial'
import { effectiveContractTypes } from '@/lib/contract-types'
import { applySmartHeaderMap, mapSmartCommercialRows, type SmartGenericRepassMap, type SmartHeaderMap, type SmartImportResult } from '@/lib/imports/smart-commercial'

export type SmartParsed=SmartImportResult&{format:SmartFormat|null;headers:{index:number;label:string}[];headerMapApplied:SmartHeaderMap;availableContractTypes:{id:string;name:string}[];availableGroups:{id:string;name:string}[]}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the scoped Supabase client is untyped in this codebase
type Ctx={supabase:{from:(table:string)=>any}}

export async function parseSmartCommercialFile(ctx:Ctx,file:File,headerMap:SmartHeaderMap={},contractTypeValueMap:Record<string,string>={},genericRepassMap:SmartGenericRepassMap={}):Promise<SmartParsed>{
 // size is checked BEFORE reading the body into memory (arrayBuffer would allocate it all)
 if(file.size===0||file.size>5_000_000)throw new Error('invalid_file')
 const read=await readSmartFile(new Uint8Array(await file.arrayBuffer()),file.name)
 if(read.issues.length||read.rows.length===0){
  // a file the reader could not turn into a table never reaches the commercial parser and never reaches the database
  const issues=read.issues.length?read.issues:[{line:1,code:'file_without_rows'}]
  return {format:read.format,headers:[],headerMapApplied:headerMap,availableContractTypes:[],availableGroups:[],rows:[],issues,summary:{sourceRows:0,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false,genericRepasseSlots:[]}}
 }
 const headers=(read.rows[0]??[]).map((x,index)=>({index,label:String(x??'').trim()||`Coluna ${index+1}`}))
 const mapped=applySmartHeaderMap(read.rows,headerMap)
 if(mapped.issue){
  return {format:read.format,headers,headerMapApplied:headerMap,availableContractTypes:[],availableGroups:[],rows:[],issues:[mapped.issue],summary:{sourceRows:Math.max(0,read.rows.length-1),expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false,genericRepasseSlots:[]}}
 }
 const raw=mapped.rows

 const [types,settings,groups,components]=await Promise.all([
  ctx.supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
  ctx.supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
  ctx.supabase.from('commission_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
  ctx.supabase.from('commission_component_types').select('id,tech_key,name,is_active').eq('is_active',true).order('sort_order'),
 ])
 const enabled=effectiveContractTypes(
  (types.data??[]) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[],
  (settings.data??[]) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[],
  'commission',
 )
 const groupRows=(groups.data??[]) as {id:string;name:string}[]
 return {format:read.format,headers,headerMapApplied:headerMap,availableContractTypes:enabled.map(t=>({id:t.id,name:t.name})),availableGroups:groupRows,...mapSmartCommercialRows(raw,{
  contractTypes:enabled,
  contractTypeValueMap,
  genericRepassMap,
  groups:groupRows,
  components:(components.data??[]) as {id:string;tech_key:string;name:string}[],
 })}
}

export const SMART_IMPORT_ISSUES:Record<string,string>={
 file_without_rows:'O arquivo não contém linhas de dados.',
 missing_bank:'Não encontrei a coluna Banco / Instituição.',
 missing_agreement:'Não encontrei a coluna Convênio.',
 missing_table:'Não encontrei a coluna Produto / Tabela.',
 missing_contract:'Não encontrei a coluna Tipo de Contrato.',
 missing_term:'Não encontrei Prazo ou Prazo Inicial.',
 missing_rate_coefficient_or_factor:'Não encontrei Taxa, Coeficiente ou Fator.',
 generic_repass_requires_mapping:'O arquivo usa Repasse 1/2/3. Vincule cada slot explicitamente a um Grupo de Comissão ou confirme que deseja ignorá-lo.',
 generic_repass_mapping_invalid:'O mapeamento de Repasse aponta para um Grupo de Comissão inválido ou inativo.',
 missing_identity:'Banco, Convênio, Tabela ou Tipo de Contrato está vazio.',
 unknown_contract_type:'Tipo de Contrato não existe ou não está habilitado.',
 invalid_term_range:'Faixa de prazo inválida.',
 invalid_number:'Taxa, coeficiente ou fator inválido.',
 rate_coefficient_or_factor_required:'A linha precisa de taxa, coeficiente ou fator.',
 invalid_date:'Data de vigência inválida.',
 factor_mode_required:'O arquivo tem fator, mas não informa se é Diário ou Fixo.',
 invalid_component_value:'Componente de comissão inválido.',
 component_unit_required:'Componente em que não foi possível determinar se é % ou R$.',
 component_percentage_over_100:'Percentual de componente acima de 100%.',
 invalid_repass_value:'Valor de repasse inválido.',
 empty_file:'Arquivo vazio.',
 unsupported_file:'Formato não suportado. Use CSV, XLSX, XLS ou PDF com texto.',
 file_too_large:'Arquivo maior que o limite (2 MB para planilhas, 5 MB para PDF).',
 file_too_large_for_import:'Planilha grande demais (máximo de 5.000 linhas / 20.000 condições por importação). Divida em partes.',
 too_many_columns:'Planilha com colunas demais.',
 zip_unreadable:'O arquivo XLSX está corrompido.',
 zip_too_many_entries:'Arquivo XLSX suspeito (partes demais).',
 zip_too_large:'Arquivo XLSX descompacta para um tamanho suspeito.',
 zip_encrypted:'Arquivo protegido por senha. Remova a senha e envie de novo.',
 zip_bad_path:'Arquivo XLSX com estrutura suspeita.',
 zip_suspicious_ratio:'Arquivo XLSX com taxa de compressão suspeita.',
 xlsx_unreadable:'Não foi possível ler o XLSX.',
 xls_unreadable:'Não foi possível ler o arquivo Excel antigo (.xls). Salve como XLSX e envie de novo.',
 html_disguised_as_excel:'O arquivo tem extensão de Excel mas é uma página HTML. Abra no Excel e salve como XLSX.',
 percent_number_format:'Há números formatados como % no Excel (ex.: 15% guardado como 0,15). Não é possível saber com segurança a unidade: salve as colunas como número (15,00) ou como texto e envie de novo.',
 unrecognized_commission_column:'Há uma coluna de comissão/valor que o sistema não reconhece. Nenhuma coluna de dinheiro é ignorada em silêncio: renomeie ou remova.',
 factor_date_required:'Fator diário exige a data do fator.',
 text_too_long:'Banco, Convênio ou Tabela com texto longo demais.',
 pdf_no_text:'PDF sem texto selecionável (imagem/escaneado). OCR não é usado automaticamente: envie XLSX/CSV ou peça revisão.',
 pdf_no_table:'Não encontrei uma tabela com cabeçalho reconhecível no PDF. Necessita revisão/mapeamento.',
 pdf_ambiguous_layout:'O PDF tem uma estrutura ambígua. Necessita revisão/mapeamento; nada foi importado.',
 pdf_too_large:'PDF maior que 5 MB.',
 pdf_too_many_pages:'PDF com páginas demais (máximo 30).',
 pdf_too_complex:'PDF complexo demais para leitura automática.',
 pdf_unreadable:'Não foi possível ler o PDF (corrompido ou protegido).',
 manual_mapping_invalid:'O mapeamento manual de colunas é inválido ou usa a mesma coluna mais de uma vez.',
}

const HEADER_FIELDS=new Set(['bank','agreement','table','externalCode','validFrom','validUntil','contract','term','termMin','termMax','coefficient','rate','factor','factorMode','factorDate'])
export function headerMapFromForm(fd:FormData){
 const raw=String(fd.get('header_map')??'').trim()
 if(!raw)return {}
 if(raw.length>2000)throw new Error('invalid_header_map')
 const parsed=JSON.parse(raw) as Record<string,unknown>
 if(!parsed||Array.isArray(parsed)||typeof parsed!=='object')throw new Error('invalid_header_map')
 const out:Record<string,number>={}
 for(const [k,v] of Object.entries(parsed)){
  if(!HEADER_FIELDS.has(k)||typeof v!=='number'||!Number.isInteger(v)||v<0||v>199)throw new Error('invalid_header_map')
  out[k]=v
 }
 return out
}

export function contractTypeMapFromForm(fd:FormData){
 const raw=String(fd.get('contract_type_map')??'').trim()
 if(!raw)return {}
 if(raw.length>4000)throw new Error('invalid_contract_type_map')
 const parsed=JSON.parse(raw) as Record<string,unknown>
 if(!parsed||Array.isArray(parsed)||typeof parsed!=='object')throw new Error('invalid_contract_type_map')
 const out:Record<string,string>={}
 for(const [source,target] of Object.entries(parsed)){
  if(!source.trim()||source.length>120||typeof target!=='string'||target.length>80)throw new Error('invalid_contract_type_map')
  out[source.trim()]=target
 }
 return out
}


export async function validateSmartPolicyScope(ctx:Ctx,organizationId:string,policyVersionId:string,rows:SmartImportResult['rows']){
 if(!policyVersionId)return {ok:true as const}
 const versionQ=await ctx.supabase.from('component_payout_policy_versions').select('id,policy_id,organization_id').eq('id',policyVersionId).eq('organization_id',organizationId).maybeSingle()
 const version=versionQ.data as {id:string;policy_id:string;organization_id:string}|null
 if(!version)return {ok:false as const,error:'Regra de comissão não encontrada para esta empresa.'}
 const policyQ=await ctx.supabase.from('component_payout_policies').select('id,org_bank_id,org_agreement_id,product_table_id,is_active').eq('id',version.policy_id).eq('organization_id',organizationId).maybeSingle()
 const policy=policyQ.data as {id:string;org_bank_id:string|null;org_agreement_id:string|null;product_table_id:string|null;is_active:boolean}|null
 if(!policy||!policy.is_active)return {ok:false as const,error:'Regra de comissão está inativa ou indisponível.'}
 const same=(a:string,b:string)=>normalizeHeader(a)===normalizeHeader(b)
 if(policy.org_bank_id){
  const q=await ctx.supabase.from('organization_banks').select('id,name').eq('id',policy.org_bank_id).eq('organization_id',organizationId).maybeSingle()
  const bank=q.data as {id:string;name:string}|null
  if(!bank||rows.some(r=>!same(r.bank_name,bank.name)))return {ok:false as const,error:'A regra de comissão selecionada pertence a outra Instituição/Origem.'}
 }
 if(policy.org_agreement_id){
  const q=await ctx.supabase.from('organization_agreements').select('id,name').eq('id',policy.org_agreement_id).eq('organization_id',organizationId).maybeSingle()
  const agreement=q.data as {id:string;name:string}|null
  if(!agreement||rows.some(r=>!same(r.agreement_name,agreement.name)))return {ok:false as const,error:'A regra de comissão selecionada pertence a outro Convênio.'}
 }
 if(policy.product_table_id){
  const q=await ctx.supabase.from('product_tables').select('id,name,route_id').eq('id',policy.product_table_id).eq('organization_id',organizationId).maybeSingle()
  const table=q.data as {id:string;name:string;route_id:string}|null
  if(!table||rows.some(r=>!same(r.table_name,table.name)))return {ok:false as const,error:'A regra de comissão selecionada pertence a outra Tabela.'}
  const routeQ=await ctx.supabase.from('organization_product_routes').select('org_bank_id,org_agreement_id').eq('id',table.route_id).eq('organization_id',organizationId).maybeSingle()
  const route=routeQ.data as {org_bank_id:string|null;org_agreement_id:string|null}|null
  if(!route)return {ok:false as const,error:'Não foi possível validar o escopo da Tabela da regra de comissão.'}
  if(route.org_bank_id){
   const bq=await ctx.supabase.from('organization_banks').select('name').eq('id',route.org_bank_id).eq('organization_id',organizationId).maybeSingle()
   const b=bq.data as {name:string}|null
   if(!b||rows.some(r=>!same(r.bank_name,b.name)))return {ok:false as const,error:'A Tabela da regra pertence a outra Instituição/Origem.'}
  }
  if(route.org_agreement_id){
   const aq=await ctx.supabase.from('organization_agreements').select('name').eq('id',route.org_agreement_id).eq('organization_id',organizationId).maybeSingle()
   const a=aq.data as {name:string}|null
   if(!a||rows.some(r=>!same(r.agreement_name,a.name)))return {ok:false as const,error:'A Tabela da regra pertence a outro Convênio.'}
  }
 }
 return {ok:true as const}
}


export type SmartPolicySuggestion={
 versionId:string
 policyId:string
 name:string
 version:number
 discount:string
 specificity:number
 scopeLabel:string
}
export async function suggestSmartPolicyScope(ctx:Ctx,organizationId:string,rows:SmartImportResult['rows']){
 if(!rows.length)return {suggested:null as SmartPolicySuggestion|null,ambiguous:[] as SmartPolicySuggestion[]}
 const [policiesQ,versionsQ,banksQ,agreementsQ,tablesQ,routesQ]=await Promise.all([
  ctx.supabase.from('component_payout_policies').select('id,name,org_bank_id,org_agreement_id,product_table_id,is_active').eq('organization_id',organizationId).eq('is_active',true),
  ctx.supabase.from('component_payout_policy_versions').select('id,policy_id,version,discount_pct,organization_id').eq('organization_id',organizationId).order('version',{ascending:false}),
  ctx.supabase.from('organization_banks').select('id,name').eq('organization_id',organizationId),
  ctx.supabase.from('organization_agreements').select('id,name').eq('organization_id',organizationId),
  ctx.supabase.from('product_tables').select('id,name,route_id').eq('organization_id',organizationId),
  ctx.supabase.from('organization_product_routes').select('id,org_bank_id,org_agreement_id').eq('organization_id',organizationId),
 ])
 const policies=(policiesQ.data??[]) as {id:string;name:string;org_bank_id:string|null;org_agreement_id:string|null;product_table_id:string|null;is_active:boolean}[]
 const versions=(versionsQ.data??[]) as {id:string;policy_id:string;version:number;discount_pct:string|number;organization_id:string}[]
 const banks=new Map(((banksQ.data??[]) as {id:string;name:string}[]).map(x=>[x.id,x.name]))
 const agreements=new Map(((agreementsQ.data??[]) as {id:string;name:string}[]).map(x=>[x.id,x.name]))
 const tables=new Map(((tablesQ.data??[]) as {id:string;name:string;route_id:string}[]).map(x=>[x.id,x]))
 const routes=new Map(((routesQ.data??[]) as {id:string;org_bank_id:string|null;org_agreement_id:string|null}[]).map(x=>[x.id,x]))
 const same=(a:string,b:string)=>normalizeHeader(a)===normalizeHeader(b)
 const candidates:SmartPolicySuggestion[]=[]
 for(const p of policies){
  const v=versions.find(x=>x.policy_id===p.id)
  if(!v)continue
  let bankName=p.org_bank_id?banks.get(p.org_bank_id)??null:null
  let agreementName=p.org_agreement_id?agreements.get(p.org_agreement_id)??null:null
  let tableName:string|null=null
  if(p.product_table_id){
   const t=tables.get(p.product_table_id)
   if(!t)continue
   tableName=t.name
   const route=routes.get(t.route_id)
   if(!bankName&&route?.org_bank_id)bankName=banks.get(route.org_bank_id)??null
   if(!agreementName&&route?.org_agreement_id)agreementName=agreements.get(route.org_agreement_id)??null
  }
  if(bankName&&rows.some(r=>!same(r.bank_name,bankName!)))continue
  if(agreementName&&rows.some(r=>!same(r.agreement_name,agreementName!)))continue
  if(tableName&&rows.some(r=>!same(r.table_name,tableName!)))continue
  const specificity=(p.product_table_id?100:0)+(p.org_agreement_id?10:0)+(p.org_bank_id?1:0)
  const scope=[tableName&&'Tabela '+tableName,agreementName&&'Convênio '+agreementName,bankName&&'Instituição '+bankName].filter(Boolean).join(' · ')||'Toda a empresa'
  candidates.push({versionId:v.id,policyId:p.id,name:p.name,version:v.version,discount:String(v.discount_pct??0),specificity,scopeLabel:scope})
 }
 if(!candidates.length)return {suggested:null,ambiguous:[]}
 const top=Math.max(...candidates.map(x=>x.specificity))
 const best=candidates.filter(x=>x.specificity===top)
 return best.length===1?{suggested:best[0],ambiguous:[]}:{suggested:null,ambiguous:best}
}


export function genericRepassMapFromForm(fd:FormData){
 const raw=String(fd.get('generic_repass_map')??'').trim()
 if(!raw)return {}
 if(raw.length>6000)throw new Error('invalid_generic_repass_map')
 const parsed=JSON.parse(raw) as Record<string,unknown>
 if(!parsed||Array.isArray(parsed)||typeof parsed!=='object')throw new Error('invalid_generic_repass_map')
 const out:SmartGenericRepassMap={}
 for(const [slot,value] of Object.entries(parsed)){
  if(!/^\d{1,2}$/.test(slot)||!value||Array.isArray(value)||typeof value!=='object')throw new Error('invalid_generic_repass_map')
  const v=value as Record<string,unknown>
  if(typeof v.group_id!=='string'||!v.group_id||!['share_of_received','direct'].includes(String(v.rule_hint))||!['percentage','fixed_brl'].includes(String(v.value_kind_hint)))throw new Error('invalid_generic_repass_map')
  out[slot]={group_id:v.group_id,rule_hint:v.rule_hint as 'share_of_received'|'direct',value_kind_hint:v.value_kind_hint as 'percentage'|'fixed_brl'}
 }
 return out
}
