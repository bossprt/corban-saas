
import { parseDelimited } from '@/lib/commercial'
import { xlsxRows } from '@/lib/commercial-xlsx'
import { effectiveContractTypes } from '@/lib/contract-types'
import { mapSmartCommercialRows, type SmartImportResult } from '@/lib/imports/smart-commercial'

type RefData={
 types:{id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[]
 settings:{contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[]
 groups:{id:string;name:string}[]
 components:{id:string;tech_key:string;name:string}[]
}

export async function parseSmartCommercialFile(file:File,refs:RefData):Promise<SmartImportResult>{
 if(file.size===0||file.size>2_000_000)throw new Error('invalid_file')
 const buf=Buffer.from(await file.arrayBuffer())
 let raw:string[][]
 const lower=file.name.toLowerCase()
 if(lower.endsWith('.xlsx')||(buf[0]===0x50&&buf[1]===0x4b)) raw=await xlsxRows(buf)
 else if(lower.endsWith('.csv')||lower.endsWith('.txt')) raw=parseDelimited(buf.toString('utf-8'))
 else throw new Error('unsupported_file')

 const enabled=effectiveContractTypes(refs.types,refs.settings,'commission')
 return mapSmartCommercialRows(raw,{contractTypes:enabled,groups:refs.groups,components:refs.components})
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
}
