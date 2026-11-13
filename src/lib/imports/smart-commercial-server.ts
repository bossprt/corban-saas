
import { readSmartFile, type SmartFormat } from '@/lib/imports/smart-file'
import { effectiveContractTypes } from '@/lib/contract-types'
import { suggestAgreement, valorPrazosRows, type ValorProduct } from '@/lib/imports/valor-prazos'
import { mapSmartCommercialRows, parseCalculationBase, type CalculationBase, type RepassMap, type SmartImportResult } from '@/lib/imports/smart-commercial'

// groupOptions: the groups a "Repasse N" column can be mapped to (active, not own production).
// valor: review of Banco Valor's "Prazos e Comissões" PDF (each product with the agreement chosen or suggested).
export type ValorReview={bankId:string|null;agreements:{id:string;name:string}[];products:(ValorProduct&{agreementIds:string[];suggested:boolean})[]}
export type SmartParsed=SmartImportResult&{format:SmartFormat|null;groupOptions:{id:string;name:string}[];valor?:ValorReview}

// "repass_map" form field: {"1":"<group uuid>","2":null}. Anything malformed is treated as "no answer".
export function parseRepassMap(raw:unknown):RepassMap{
 try{
  const v=JSON.parse(String(raw??'{}')) as Record<string,unknown>
  const out:RepassMap={}
  for(const [k,g] of Object.entries(v??{})){
   if(!/^\d{1,2}$/.test(k))continue
   if(g===null)out[k]=null
   else if(typeof g==='string'&&/^[0-9a-f-]{36}$/i.test(g))out[k]=g
  }
  return out
 }catch{return {}}
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the scoped Supabase client is untyped in this codebase
type Ctx={supabase:{from:(table:string)=>any}}

// "calculation_base" form field: the base chosen for a file that does not carry one (Bruto or Líquido).
export const parseBaseChoice=(raw:unknown):CalculationBase|undefined=>typeof raw==='string'&&raw?parseCalculationBase(raw)??undefined:undefined

// "agreement_map" form field: {"<product key>":["<agreement uuid>",...]} for Banco Valor's PDF (a product may go to
// several agreements). Malformed entries = no answer; an empty list is an answer only to be refused later (none chosen).
export function parseAgreementMap(raw:unknown):Record<string,string[]>{
 try{
  const v=JSON.parse(String(raw??'{}')) as Record<string,unknown>
  const out:Record<string,string[]>={}
  for(const [k,g] of Object.entries(v??{})){
   if(!/^[a-z0-9_]{1,80}$/.test(k))continue
   const list=(Array.isArray(g)?g:[g]).filter((x):x is string=>typeof x==='string'&&/^[0-9a-f-]{36}$/i.test(x))
   if(Array.isArray(g)||list.length)out[k]=[...new Set(list)].slice(0,100)
  }
  return out
 }catch{return {}}
}

// "bank_id" form field: the bank chosen for a file without a bank column (Bevicred table). Only a uuid is accepted.
export const parseBankChoice=(raw:unknown):string|undefined=>typeof raw==='string'&&/^[0-9a-f-]{36}$/i.test(raw)?raw:undefined

export async function parseSmartCommercialFile(ctx:Ctx,file:File,repassMap:RepassMap={},defaultBase?:CalculationBase,bankId?:string,agreementMap:Record<string,string[]>={}):Promise<SmartParsed>{
 // size is checked BEFORE reading the body into memory (arrayBuffer would allocate it all)
 if(file.size===0||file.size>5_000_000)throw new Error('invalid_file')
 const read=await readSmartFile(new Uint8Array(await file.arrayBuffer()),file.name)
 // Banco Valor's PDF: the bank and every product's agreement are the company's own active records, chosen on screen
 // (a product whose PDF names the agreement comes suggested). Until all are chosen the import stays blocked.
 let valor:ValorReview|undefined
 const valorPending:string[]=[]
 if(read.format==='valor_prazos'&&read.valor&&!read.issues.length){
  const [banksRes,agreementsRes]=await Promise.all([
   ctx.supabase.from('organization_banks').select('id,name').eq('is_active',true).order('name'),
   ctx.supabase.from('organization_agreements').select('id,name').eq('is_active',true).order('name'),
  ])
  const banks=(banksRes.data??[]) as {id:string;name:string}[]
  const agreements=(agreementsRes.data??[]) as {id:string;name:string}[]
  // a bank chosen on screen must be one of the company's; with none chosen, the only bank named "Valor" is taken
  const valorBanks=banks.filter(b=>/\bvalor\b/i.test(b.name))
  const bank=bankId?banks.find(b=>b.id===bankId)??null:valorBanks.length===1?valorBanks[0]:null
  const known=new Set(agreements.map(a=>a.id))
  const products=read.valor.map(p=>{
   const answered=Object.prototype.hasOwnProperty.call(agreementMap,p.key)
   const hint=answered?null:suggestAgreement(p.hint,agreements)
   return {...p,agreementIds:answered?agreementMap[p.key].filter(id=>known.has(id)):hint?[hint.id]:[],suggested:!answered&&!!hint}
  })
  valor={bankId:bank?.id??null,agreements,products}
  const nameOf=new Map(agreements.map(a=>[a.id,a.name]))
  read.rows=valorPrazosRows(read.valor,bank?.name??'(escolha o banco)',key=>(products.find(p=>p.key===key)?.agreementIds??[]).map(id=>nameOf.get(id)!).filter(Boolean))
  if(!bank)valorPending.push('bank_choice_required')
  if(products.some(p=>!p.agreementIds.length))valorPending.push('agreement_choice_required')
  if(Object.values(agreementMap).flat().some(id=>!nameOf.has(id)))valorPending.push('agreement_map_invalid')
 }
 if(read.issues.length||read.rows.length===0){
  // a file the reader could not turn into a table never reaches the commercial parser and never reaches the database
  const issues=read.issues.length?read.issues:[{line:1,code:'file_without_rows'}]
  return {format:read.format,groupOptions:[],rows:[],issues,summary:{sourceRows:0,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false,genericRepasseSlots:[]}}
 }
 let raw=read.rows
 // The Bevicred table has no bank column: the bank chosen on screen goes into every line. Until it is chosen the
 // preview runs with a placeholder and the import stays blocked (bank_choice_required).
 let bankPending=false
 if(read.format==='bevicred'){
  const bank=bankId?(await ctx.supabase.from('organization_banks').select('name').eq('id',bankId).maybeSingle()).data as {name:string}|null:null
  bankPending=!bank
  raw=raw.map((r,i)=>[i===0?'Banco':bank?.name??'(escolha o banco)',...r])
 }

 const [types,settings,groups,components,rules,providers]=await Promise.all([
  ctx.supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
  ctx.supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
  ctx.supabase.from('commission_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
  ctx.supabase.from('commission_component_types').select('id,tech_key,name,is_active').eq('is_active',true).order('sort_order'),
  ctx.supabase.from('commission_group_rules').select('group_id,version,own_production').order('version',{ascending:false}),
  ctx.supabase.from('organization_providers').select('id,name').eq('is_active',true),
 ])
 // Own-production groups have no columns: a column named after one is an unknown group.
 const current=new Map<string,boolean>()
 for(const r of (rules.data??[]) as {group_id:string;own_production:boolean}[])if(!current.has(r.group_id))current.set(r.group_id,r.own_production)
 const payable=((groups.data??[]) as {id:string;name:string}[]).filter(g=>!current.get(g.id))
 const enabled=effectiveContractTypes(
  (types.data??[]) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[],
  (settings.data??[]) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[],
  'commission',
 )
 const mapped=mapSmartCommercialRows(raw,{
  contractTypes:enabled,
  groups:payable,
  components:(components.data??[]) as {id:string;tech_key:string;name:string}[],
  repassMap,
  defaultBase,
  providers:(providers.data??[]) as {id:string;name:string}[],
 })
 if(bankPending)mapped.issues.unshift({line:1,code:'bank_choice_required'})
 for(const code of valorPending.reverse())mapped.issues.unshift({line:1,code})
 return {format:read.format,groupOptions:payable,...mapped,...(valor?{valor}:{})}
}

export const SMART_IMPORT_ISSUES:Record<string,string>={
 file_without_rows:'O arquivo não contém linhas de dados.',
 bank_choice_required:'O arquivo não diz o banco cadastrado. Escolha o banco abaixo para continuar.',
 agreement_choice_required:'Há produtos sem convênio. Escolha o convênio de cada produto abaixo para continuar.',
 agreement_map_invalid:'Um produto foi ligado a um convênio que não existe ou está inativo.',
 valor_prazos_layout:'O PDF "Prazos e Comissões" da Valor veio num formato diferente do esperado. Nada foi importado: avise o suporte.',
 bevicred_layout_changed:'A tabela da Bevicred mudou de formato (colunas diferentes do esperado). Nada foi importado: avise o suporte.',
 bevicred_unknown_contract_type:'Tabela da Bevicred sem tipo de contrato reconhecível no nome (Novo, Refin, Portabilidade ou Refin da Portabilidade).',
 bevicred_unknown_agreement:'Tabela da Bevicred sem convênio reconhecível no nome (INSS ou Gov. Acre).',
 bevicred_contract_form:'A coluna "Forma Contrato" da Bevicred veio com um tipo que o sistema não conhece (aceitos: Novo, Refin, Portabilidade, Refin da Portabilidade, Transferência). Nada foi importado: avise o suporte.',
 bevicred_monthly_deferred:'A tabela tem "Diferido Mensal" da Bevicred, que o sistema ainda não lê. Nada foi importado: avise o suporte.',
 bevicred_total_mismatch:'"Comissão Total" diferente da soma Vista + Diferido nesta tabela da Bevicred.',
 bevicred_invalid_number:'Número inválido na tabela da Bevicred.',
 missing_bank:'Não encontrei a coluna Banco / Instituição.',
 missing_agreement:'Não encontrei a coluna Convênio.',
 missing_table:'Não encontrei a coluna Produto / Tabela.',
 missing_contract:'Não encontrei a coluna Tipo de Contrato.',
 missing_term:'Não encontrei Prazo ou Prazo Inicial.',
 generic_repass_requires_mapping:'O arquivo usa colunas "Repasse N". Escolha o grupo de vendedores de cada uma (ou "Não usar") para continuar.',
 unknown_group_column:'Há uma coluna de grupo que não existe no Corban (ou é produção própria). Cadastre o grupo em Grupos de vendedores ou corrija o nome da coluna.',
 repass_map_invalid_group:'Um Repasse foi ligado a um grupo que não existe ou não pode receber repasse.',
 duplicate_group_column:'O mesmo grupo recebeu duas colunas para o mesmo tipo de comissão (confira o mapeamento dos Repasses).',
 missing_identity:'Banco, Convênio, Tabela ou Tipo de Contrato está vazio.',
 unknown_contract_type:'Tipo de Contrato não existe ou não está habilitado.',
 invalid_term_range:'Faixa de prazo inválida.',
 invalid_number:'Taxa, coeficiente ou fator inválido.',
 invalid_amount_range:'Faixa de valor inválida: preencha Valor Inicial e Valor Final (R$), com o final maior ou igual ao inicial.',
 invalid_date:'Data de vigência inválida.',
 factor_mode_required:'O arquivo tem fator, mas não informa se é Diário ou Fixo.',
 invalid_component_value:'Componente de comissão inválido.',
 component_unit_required:'Componente em que não foi possível determinar se é % ou R$.',
 component_percentage_over_100:'Percentual de componente acima de 100%.',
 invalid_repass_value:'Valor de repasse inválido.',
 calculation_base_required:'A planilha não diz a base de cálculo das comissões (bruto ou líquido). Escolha abaixo para continuar.',
 invalid_calculation_base:'Base de cálculo inválida: use Bruto ou Líquido.',
 missing_calculation_base:'Linha sem base de cálculo (Bruto ou Líquido).',
 unknown_provider:'Promotora parceira não cadastrada (ou inativa): confira o nome na coluna "Promotora parceira" (vazio = produção própria).',
 invalid_formalization:'Tipo de formalização inválido: use "Digital" ou "Físico" (vazio = digital).',
 formalization_conflict:'A mesma tabela veio com linhas digitais e físicas: uma tabela tem um só tipo de formalização.',
 invalid_tax:'Imposto inválido: use um percentual de 0 a 100 (vazio = não paga imposto).',
 empty_file:'Arquivo vazio.',
 unsupported_file:'Formato não suportado. Use CSV, XLSX, XLS, PDF com texto ou a tabela da Bevicred.',
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
}
