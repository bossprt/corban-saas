import test from 'node:test'
import assert from 'node:assert/strict'
import ExcelJS from 'exceljs'
import { prepareImport,ImportPipelineError,MAX_IMPORT_BYTES } from '../../src/lib/imports/pipeline'
import { matchNormalizedRow } from '../../src/lib/imports/matcher'
import { sha256 } from '../../src/lib/imports/engine'

const csv=(s:string)=>Buffer.from(s,'utf8')
const fails=async(p:Promise<unknown>,code:string)=>{
 await assert.rejects(p,(e:unknown)=>e instanceof ImportPipelineError&&e.code===code)
}

test('2Tech CSV runs end to end through the generic pipeline and preserves raw rows',async()=>{
 const buf=csv('NumeroProposta;StatusProposta;ComissaoRepasseValor;ColunaNova\n1;Averbada;0,00;z\n')
 const p=await prepareImport({filename:'a.csv',buffer:buf,sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'})
 assert.equal(p.adapter.key,'2tech/busca_contrato_file')
 assert.equal(p.contentSha256,sha256(buf))
 assert.deepEqual(p.rows[0].rawPayload,{NumeroProposta:'1',StatusProposta:'Averbada',ComissaoRepasseValor:'0,00',ColunaNova:'z'})
 assert.deepEqual(p.headers,['NumeroProposta','StatusProposta','ComissaoRepasseValor','ColunaNova'])
})

test('source semantic must equal the adapter semantic (no cross-semantic ingestion)',async()=>{
 const buf=csv('NumeroProposta;StatusProposta\n1;x\n')
 await fails(prepareImport({filename:'a.csv',buffer:buf,sourceKey:'2tech_busca_contrato',sourceSemantic:'commercial_offer'}),'semantic_mismatch')
 await fails(prepareImport({filename:'a.csv',buffer:buf,sourceKey:'2tech_busca_contrato',sourceSemantic:'payment_statement'}),'semantic_mismatch')
})

test('a commercial-offer adapter can never be paired with a payment source',async()=>{
 const buf=csv('Codigo;Tabela;Prazo;Taxa\nA;T;12;1,5\n')
 await fails(prepareImport({filename:'a.csv',buffer:buf,sourceKey:'daycoval',sourceSemantic:'payment_statement'}),'semantic_mismatch')
})

test('empty, oversized, unsupported and binary-XLS files are rejected',async()=>{
 await fails(prepareImport({filename:'a.csv',buffer:Buffer.alloc(0),sourceKey:'daycoval',sourceSemantic:'commercial_offer'}),'empty_file')
 await fails(prepareImport({filename:'a.csv',buffer:Buffer.alloc(MAX_IMPORT_BYTES+1),sourceKey:'daycoval',sourceSemantic:'commercial_offer'}),'file_too_large')
 await fails(prepareImport({filename:'a.pdf',buffer:csv('x'),sourceKey:'daycoval',sourceSemantic:'commercial_offer'}),'unsupported_format')
 await fails(prepareImport({filename:'a.xls',buffer:Buffer.from([0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1]),sourceKey:'daycoval',sourceSemantic:'commercial_offer'}),'xls_binary_unsupported')
})

test('header-only or malformed files fail closed with an explicit error',async()=>{
 await fails(prepareImport({filename:'a.csv',buffer:csv('NumeroProposta;StatusProposta\n'),sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'}),'unreadable_file')
})

test('unknown source key without a unique auto-detect fails closed',async()=>{
 await fails(prepareImport({filename:'a.csv',buffer:csv('a;b\n1;2\n'),sourceKey:'nope',sourceSemantic:'commercial_offer'}),'adapter_not_found')
})

test('xlsx and html-as-xls give the same normalized rows as csv (format independence)',async()=>{
 const wb=new ExcelJS.Workbook();const ws=wb.addWorksheet('a')
 ws.addRow(['NumeroProposta','StatusProposta']);ws.addRow(['5','Paga'])
 const x=await prepareImport({filename:'a.xlsx',buffer:Buffer.from(await wb.xlsx.writeBuffer()),sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'})
 const h=await prepareImport({filename:'a.xls',buffer:Buffer.from('<table><tr><th>NumeroProposta</th><th>StatusProposta</th></tr><tr><td>5</td><td>Paga</td></tr></table>','latin1'),sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'})
 const c=await prepareImport({filename:'a.csv',buffer:csv('NumeroProposta;StatusProposta\n5;Paga\n'),sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'})
 assert.deepEqual(x.rows.map(r=>r.normalized),c.rows.map(r=>r.normalized))
 assert.deepEqual(h.rows.map(r=>r.normalized),c.rows.map(r=>r.normalized))
})

test('duplicate file bytes yield the same SHA-256 (idempotent replay key)',async()=>{
 const buf=csv('NumeroProposta;StatusProposta\n5;Paga\n')
 const a=await prepareImport({filename:'a.csv',buffer:buf,sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'})
 const b=await prepareImport({filename:'renamed.csv',buffer:Buffer.from(buf),sourceKey:'2tech_busca_contrato',sourceSemantic:'production_report'})
 assert.equal(a.contentSha256,b.contentSha256)
})

test('matcher compares institutions case-insensitively (mirrors SQL lower())',()=>{
 const row={recordKind:'proposal' as const,bankKey:'Daycoval',externalProposalNumber:'9',producerTaxId:null,externalTableCode:null,externalTableName:null,operationType:null,term:null,rate:null,commissionUpfront:null,commissionDeferred:null,amount:null,normalizedPayload:{}}
 const m=matchNormalizedRow(row,{proposals:[{id:'p',institutionKey:'daycoval',externalProposalNumber:'9'}],tables:[]})
 assert.equal(m.strength,'exact')
})
