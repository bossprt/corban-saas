import test from 'node:test'
import assert from 'node:assert/strict'
import ExcelJS from 'exceljs'
import { twoTechBuscaContratoAdapter,analyzeTwoTechSchema,classifyCommission,schemaFingerprint } from '../../src/lib/imports/twotech'
import { parseCsv,parseHtmlTable } from '../../src/lib/imports/tabular'
import { parseXlsx } from '../../src/lib/imports/xlsx'
import { assertFinancialPublicationAllowed,selectImportAdapter } from '../../src/lib/imports/engine'

const parse=(rows:Record<string,unknown>[])=>twoTechBuscaContratoAdapter.parse({filename:'x.csv',rows})

test('statuses stay independent and raw fields are preserved',()=>{
 const raw={NumeroProposta:' 123 ',StatusBancoCliente:'Pago ao cliente',StatusEmpresaVendedor:'Pendente',StatusProposta:'Averbada',ComissaoRepasseValor:'1.234,50',Extra:'keep'}
 const [row]=parse([raw])
 assert.deepEqual(row.rawPayload,raw)
 assert.equal(row.normalized.recordKind,'proposal')
 assert.equal(row.normalized.externalProposalNumber,'123')
 assert.deepEqual((row.normalized.normalizedPayload as any).source_status,{bank_client:'Pago ao cliente',company_vendor:'Pendente',proposal:'Averbada'})
 assert.equal((row.normalized.normalizedPayload as any).Extra,'keep')
 assert.equal((row.normalized.normalizedPayload as any).canonicalStatus,null)
})

test('generic paid-like status text is never promoted to canonical paid',()=>{
 const [row]=parse([{NumeroProposta:'1',StatusBancoCliente:'PAGO',StatusEmpresaVendedor:'PAGO',StatusProposta:'PAGO'}])
 assert.equal((row.normalized.normalizedPayload as any).canonicalStatus,null)
 assert.equal(row.normalized.amount,null)
})

test('blank and zero commission are distinct from each other and never mean absence of revenue',()=>{
 assert.deepEqual(classifyCommission(''),{value:null,state:'not_reported'})
 assert.deepEqual(classifyCommission(undefined),{value:null,state:'not_reported'})
 assert.deepEqual(classifyCommission('0,00'),{value:'0.00',state:'reported_zero'})
 assert.deepEqual(classifyCommission(0),{value:'0',state:'reported_zero'})
 assert.deepEqual(classifyCommission('R$ 12,30'),{value:'12.30',state:'reported'})
 assert.equal(classifyCommission('abc').state,'unparseable')
 const [row]=parse([{NumeroProposta:'1',ComissaoRepasseValor:''}])
 assert.equal((row.normalized.normalizedPayload as any).source_commission.absence_of_revenue_inferred,false)
})

test('institution is never defaulted from the provider',()=>{
 const [row]=parse([{NumeroProposta:'1',StatusProposta:'x'}])
 assert.equal(row.normalized.bankKey,null)
 const [withBank]=parse([{NumeroProposta:'1',StatusProposta:'x',Banco:'Daycoval'}])
 assert.equal(withBank.normalized.bankKey,'Daycoval')
})

test('unknown schema is quarantined and cannot emit proposal rows',()=>{
 const rows=parse([{Foo:'1',Bar:'2'}])
 assert.equal(rows[0].normalized.recordKind,'other')
 assert.equal(rows[0].normalized.externalProposalNumber,null)
 assert.equal((rows[0].normalized.normalizedPayload as any).quarantine.reason,'missing_proposal_identity_column')
 assert.equal(analyzeTwoTechSchema([]).state,'quarantined')
 assert.equal(analyzeTwoTechSchema(['NumeroProposta']).quarantineReason,'no_known_source_semantics_column')
})

test('row without identity is quarantined individually (DB requires identity for proposal rows)',()=>{
 const rows=parse([{NumeroProposta:'1',StatusProposta:'a'},{NumeroProposta:'',StatusProposta:'b'}])
 assert.equal(rows[0].normalized.recordKind,'proposal')
 assert.equal(rows[1].normalized.recordKind,'other')
 assert.equal((rows[1].normalized.normalizedPayload as any).quarantine.reason,'missing_proposal_identity')
})

test('schema fingerprint is order/case/accent insensitive and change-sensitive; unverified until real file registered',()=>{
 assert.equal(schemaFingerprint(['NumeroProposta','StatusProposta']),schemaFingerprint(['statusproposta','Número Proposta']))
 assert.notEqual(schemaFingerprint(['NumeroProposta']),schemaFingerprint(['NumeroProposta','Novo']))
 const [row]=parse([{NumeroProposta:'1',StatusProposta:'a',ColunaNova:'z'}])
 const schema=(row.normalized.normalizedPayload as any).schema
 assert.equal(schema.fingerprint_known,false)
 assert.deepEqual(schema.unmapped_headers,['ColunaNova'])
})

test('adapter never claims commission/payment financial semantics',()=>{
 assert.equal(twoTechBuscaContratoAdapter.financialSemantic,'production_report')
 assert.throws(()=>assertFinancialPublicationAllowed(twoTechBuscaContratoAdapter),/source_does_not_prove_financial_fact/)
 assert.equal(selectImportAdapter({filename:'a.xlsx',sourceKey:'2tech_busca_contrato'}),twoTechBuscaContratoAdapter)
})

test('CSV, HTML-as-Excel and XLSX produce identical normalized rows',async()=>{
 const csv='NumeroProposta;StatusProposta;ComissaoRepasseValor\n77;Averbada;10,50\n78;Cancelada;0,00\n'
 const html='<table><tr><th>NumeroProposta</th><th>StatusProposta</th><th>ComissaoRepasseValor</th></tr><tr><td>77</td><td>Averbada</td><td>10,50</td></tr><tr><td>78</td><td>Cancelada</td><td>0,00</td></tr></table>'
 const wb=new ExcelJS.Workbook();const ws=wb.addWorksheet('a')
 ws.addRow(['NumeroProposta','StatusProposta','ComissaoRepasseValor']);ws.addRow(['77','Averbada','10,50']);ws.addRow(['78','Cancelada','0,00'])
 const xlsx=await parseXlsx(Buffer.from(await wb.xlsx.writeBuffer()))
 const a=parse(parseCsv(csv)).map(r=>r.normalized)
 const b=parse(parseHtmlTable(html)).map(r=>r.normalized)
 const c=parse(xlsx).map(r=>r.normalized)
 assert.deepEqual(b,a)
 assert.deepEqual(c,a)
 assert.equal((a[1].normalizedPayload as any).source_commission.state,'reported_zero')
})

test('replay of the same rows is deterministic',()=>{
 const rows=[{NumeroProposta:'1',StatusProposta:'a',ComissaoRepasseValor:'1,00'}]
 assert.deepEqual(parse(rows),parse(rows))
})
