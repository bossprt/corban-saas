import {decimalString,ImportAdapter,NormalizedImportRow,ParsedImportRow} from './contract'

const val=(r:Record<string,unknown>,...keys:string[])=>{for(const k of keys)if(r[k]!==undefined&&r[k]!==null&&r[k]!=='')return r[k];return null}
const text=(v:unknown)=>v==null?null:String(v).trim()||null

function base(r:Record<string,unknown>,overrides:Partial<NormalizedImportRow>):NormalizedImportRow{
 return {recordKind:'table_offer',bankKey:null,externalProposalNumber:null,producerTaxId:null,externalTableCode:null,externalTableName:null,operationType:null,term:null,rate:null,commissionUpfront:null,commissionDeferred:null,amount:null,normalizedPayload:r,...overrides}
}

export const bevicredAdapter:ImportAdapter={
 key:'bevicred-table-offer',version:'1.0.0',financialSemantic:'commercial_offer',
 canParse:({filename})=>/\.xls$/i.test(filename),
 parse:({rows})=>rows.map((r,i):ParsedImportRow=>({rowNumber:i+1,rawPayload:r,normalized:base(r,{
   bankKey:'daycoval',
   externalTableCode:text(val(r,'Descrição Banco','descricao_banco','bank_table_code')),
   externalTableName:text(val(r,'Convênio','convenio','description')),
   operationType:text(val(r,'Forma Contrato','forma_contrato','operation_type')),
   term:Number(val(r,'Prazo','prazo','term'))||null,
   rate:decimalString(val(r,'Taxa Vista','Taxa','taxa','rate')),
   commissionUpfront:decimalString(val(r,'Comissão Vista','Comissao Vista','comissao_vista','commission_upfront')),
   commissionDeferred:decimalString(val(r,'Diferido Total','diferido_total','commission_deferred')),
   normalizedPayload:{...r,channelTableCode:val(r,'Código','codigo','channel_table_code')}
 })}))}

export const daycovalAdapter:ImportAdapter={
 key:'daycoval-table-offer',version:'1.0.0',financialSemantic:'commercial_offer',
 canParse:({filename})=>/\.xlsx$/i.test(filename),
 parse:({rows})=>rows.map((r,i):ParsedImportRow=>({rowNumber:i+1,rawPayload:r,normalized:base(r,{
   bankKey:'daycoval',
   externalTableCode:text(val(r,'Código','Codigo','codigo','code')),
   externalTableName:text(val(r,'Tabela','Descrição','Descricao','descricao','name')),
   operationType:text(val(r,'Operação','Operacao','operacao','operation')),
   term:Number(val(r,'Prazo','prazo','term'))||null,
   rate:decimalString(val(r,'Taxa','taxa','rate')),
   commissionUpfront:decimalString(val(r,'À Vista','A Vista','Vista','comissao_vista')),
   commissionDeferred:decimalString(val(r,'Diferido','diferido'))
 })}))}

export const efetivaMaisAdapter:ImportAdapter={
 key:'efetiva-mais-table-offer',version:'1.0.0',financialSemantic:'commercial_offer',
 canParse:({filename})=>/\.(xlsx|xls|csv)$/i.test(filename),
 parse:({rows})=>rows.map((r,i):ParsedImportRow=>({rowNumber:i+1,rawPayload:r,normalized:base(r,{
   bankKey:text(val(r,'Banco','banco','bank')),
   externalTableCode:text(val(r,'Código Tabela','Codigo Tabela','codigo_tabela','table_code')),
   externalTableName:text(val(r,'Tabela','tabela','table_name')),
   operationType:text(val(r,'Operação','Operacao','operacao','operation')),
   term:Number(val(r,'Prazo','prazo','term'))||null,
   rate:decimalString(val(r,'Taxa','taxa','rate')),
   commissionUpfront:decimalString(val(r,'Comissão','Comissao','comissao','commission'))
 })}))}

export const importAdapters=[daycovalAdapter,efetivaMaisAdapter,bevicredAdapter]
