import test from 'node:test'
import assert from 'node:assert/strict'
import { mapSmartCommercialRows } from '../../src/lib/imports/smart-commercial'

const ctx={
 contractTypes:[
  {id:'00000000-0000-4000-8000-000000000001',name:'Novo',tech_key:'novo'},
  {id:'00000000-0000-4000-8000-000000000002',name:'Refin/Portabilidade',tech_key:'refin_portabilidade'},
 ],
 groups:[
  {id:'00000000-0000-4000-8000-000000000010',name:'Corretor'},
  {id:'00000000-0000-4000-8000-000000000011',name:'Parceiro'},
 ],
 components:[
  {id:'00000000-0000-4000-8000-000000000020',tech_key:'upfront',name:'À Vista'},
  {id:'00000000-0000-4000-8000-000000000021',tech_key:'deferred',name:'Diferido'},
  {id:'00000000-0000-4000-8000-000000000022',tech_key:'plastic',name:'Plástico'},
 ],
 // the base chosen on screen for files without a "Base de Cálculo" column
 defaultBase:'BRUTO' as const,
}

test('maps HOPE-style row and expands term range',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo Inicial','Prazo Final','Taxa a.m.','Tipo Fator','Fator','À Vista (Empresa) - Valor','À Vista (Empresa) - Unidade [% ou R$]','Data Fator'],
  ['HOPE','Gov. AC','Tabela 001','Refin/Portabilidade','12','14','1,80','DIÁRIO','0,031234','10','%','15/09/2026'],
 ],ctx)
 assert.equal(r.issues.length,0)
 assert.equal(r.rows.length,3)
 assert.equal(r.rows[0].contract_type_name,'Refin/Portabilidade')
 assert.equal(r.rows[0].factor_mode,'daily')
 assert.equal(r.rows[0].components[0].value_kind,'percentage')
 assert.equal(r.summary.tables.length,1)
})

test('generic Repasse 1 is never silently mapped to a group',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo','Taxa','À Vista (Empresa)','À Vista (Repasse 1)'],
  ['HOPE','Gov. AC','Tabela 001','Novo','84','1.8','10','6.5'],
 ],ctx)
 assert.equal(r.summary.hasGenericRepasseColumns,true)
 assert.ok(r.issues.some(x=>x.code==='generic_repass_requires_mapping'))
})

test('a plain number is % of the operation; R$ in the cell is a fixed amount (owner decision, part B)',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo','Taxa','À Vista (Empresa)','Plástico (Empresa)'],
  ['HOPE','Gov. AC','Cartão','Novo','84','1.8','5','R$ 1.250,50'],
 ],ctx)
 assert.deepEqual(r.issues,[])
 assert.deepEqual(r.rows[0].components.map(c=>[c.value_kind,c.received_value]),[['percentage','5'],['fixed_brl','1250.50']])
})

test('zero deferred is ignored and does not trigger question',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo','Taxa','Diferido (Empresa)'],
  ['HOPE','Gov. AC','Tabela 001','Novo','84','1.8','0'],
 ],ctx)
 assert.equal(r.summary.hasDeferred,false)
 assert.equal(r.issues.length,0)
})

test('Valor Inicial / Valor Final become the amount range of the line (BR or Excel numbers); no rate needed',()=>{
 const H=['Banco','Convênio','Tabela','Tipo de Contrato','Prazo Inicial','Prazo Final','Valor Inicial','Valor Final','Base de Cálculo','À Vista (Empresa)','À Vista (Corretor)']
 const r=mapSmartCommercialRows([H,
  ['FINTECH CORBAN','FGTS','BFFUNDO','Novo','1','2','40','150','Líquido','45','29,25'],
  ['FINTECH CORBAN','FGTS','BFFUNDO','Novo','1','2','150,01','R$ 250,00','Líquido','35','22,75'],
  ['FINTECH CORBAN','FGTS','BFFUNDO','Novo','1','2','1.000,50','49999.99','Líquido','18,5','12,025'],
 ],ctx)
 assert.deepEqual(r.issues,[])
 assert.equal(r.rows.length,6)
 assert.deepEqual(r.rows.filter(x=>x.term===1).map(x=>[x.amount_min,x.amount_max]),[['40','150'],['150.01','250.00'],['1000.50','49999.99']])
 assert.equal(r.rows[0].rate,null)
})

test('an amount range needs both ends, the end not below the start, and valid numbers',()=>{
 const H=['Banco','Convênio','Tabela','Tipo de Contrato','Prazo','Valor Inicial','Valor Final','Base de Cálculo','À Vista (Empresa)']
 for(const [a,b] of [['40',''],['','150'],['200','150'],['abc','150'],['1.000.000.000,00','2.000.000.000,00']]){
  const r=mapSmartCommercialRows([H,['B','C','T','Novo','12',a,b,'Bruto','5']],ctx)
  assert.equal(r.issues[0]?.code,'invalid_amount_range',`${a} / ${b}`)
 }
 const none=mapSmartCommercialRows([H,['B','C','T','Novo','12','','','Bruto','5']],ctx)
 assert.deepEqual(none.issues,[]); assert.equal(none.rows[0].amount_min,undefined)
})
