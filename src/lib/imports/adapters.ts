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
 canParse:({filename})=>/\.(xlsx|csv)$/i.test(filename),
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



function financialStatementAdapter(key:string,semantic:'commission_statement'|'payment_statement'|'network_payment_statement',recordKind:'commission'|'payment'):ImportAdapter{
 return {
  key,version:'1.0.0',financialSemantic:semantic,
  canParse:({filename})=>/\.csv$/i.test(filename),
  parse:({rows})=>rows.map((r,i):ParsedImportRow=>({rowNumber:i+1,rawPayload:r,normalized:base(r,{
   recordKind,
   bankKey:text(val(r,'Banco','banco','bank','institution')),
   externalProposalNumber:text(val(r,'Proposta','proposta','proposal','proposal_number','numero_proposta')),
   producerTaxId:text(val(r,'CNPJ Produtor','cnpj_produtor','producer_tax_id','cnpj')),
   externalTableCode:text(val(r,'Código Tabela','Codigo Tabela','codigo_tabela','table_code')),
   operationType:text(val(r,'Operação','Operacao','operacao','operation')),
   amount:decimalString(val(r,'Valor','valor','amount','commission_amount','payment_amount')),
   normalizedPayload:{...r,componentType:text(val(r,'Componente','componente','component_type'))??'upfront',occurredAt:text(val(r,'Data','data','date','occurred_at')),currency:text(val(r,'Moeda','moeda','currency'))??'BRL'}
  })}))
 }
}

export const productionStatusAdapter:ImportAdapter={
 key:'generic-production-status',version:'1.0.0',financialSemantic:'production_report',
 canParse:({filename})=>/\.csv$/i.test(filename),
 parse:({rows})=>rows.map((r,i):ParsedImportRow=>{const rawStatus=text(val(r,'Status','status','Situação','Situacao','situacao'));const canonical=rawStatus&&/^(pago|paid|liberado|creditado)$/i.test(rawStatus)?'paid':null;return {rowNumber:i+1,rawPayload:r,normalized:base(r,{
  recordKind:'status',bankKey:text(val(r,'Banco','banco','bank','institution')),externalProposalNumber:text(val(r,'Proposta','proposta','proposal','proposal_number','numero_proposta')),
  producerTaxId:text(val(r,'CNPJ Produtor','cnpj_produtor','producer_tax_id','cnpj')),
  normalizedPayload:{...r,rawStatus,canonicalStatus:canonical,occurredAt:text(val(r,'Data','data','date','occurred_at'))}
 })}})
}

export const commissionStatementAdapter=financialStatementAdapter('generic-commission-statement','commission_statement','commission')
export const paymentStatementAdapter=financialStatementAdapter('generic-payment-statement','payment_statement','payment')
export const networkPaymentStatementAdapter=financialStatementAdapter('generic-network-payment-statement','network_payment_statement','payment')

export const importAdapters=[daycovalAdapter,efetivaMaisAdapter,bevicredAdapter,productionStatusAdapter,commissionStatementAdapter,paymentStatementAdapter,networkPaymentStatementAdapter]
