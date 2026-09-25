
import { readSmartFile, type SmartFormat } from '@/lib/imports/smart-file'
import { effectiveContractTypes } from '@/lib/contract-types'
import { mapSmartCommercialRows, type SmartImportResult } from '@/lib/imports/smart-commercial'

export type SmartParsed=SmartImportResult&{format:SmartFormat|null}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the scoped Supabase client is untyped in this codebase
type Ctx={supabase:{from:(table:string)=>any}}

export async function parseSmartCommercialFile(ctx:Ctx,file:File):Promise<SmartParsed>{
 // size is checked BEFORE reading the body into memory (arrayBuffer would allocate it all)
 if(file.size===0||file.size>5_000_000)throw new Error('invalid_file')
 const read=await readSmartFile(new Uint8Array(await file.arrayBuffer()),file.name)
 if(read.issues.length||read.rows.length===0){
  // a file the reader could not turn into a table never reaches the commercial parser and never reaches the database
  const issues=read.issues.length?read.issues:[{line:1,code:'file_without_rows'}]
  return {format:read.format,rows:[],issues,summary:{sourceRows:0,expandedRows:0,tables:[],components:[],hasDeferred:false,hasPlastic:false,hasBonus:false,hasGenericRepasseColumns:false,genericRepasseSlots:[]}}
 }
 const raw=read.rows

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
 return {format:read.format,...mapSmartCommercialRows(raw,{
  contractTypes:enabled,
  groups:(groups.data??[]) as {id:string;name:string}[],
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
 generic_repass_requires_mapping:'O arquivo usa Repasse 1/2/3. Esses repasses não serão usados como regra interna sem confirmação.',
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
}
