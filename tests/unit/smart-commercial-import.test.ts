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
}

test('maps HOPE-style row and expands term range',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo Inicial','Prazo Final','Taxa a.m.','Tipo Fator','Fator','À Vista (Empresa) - Valor','À Vista (Empresa) - Unidade [% ou R$]'],
  ['HOPE','Gov. AC','Tabela 001','Refin/Portabilidade','12','14','1,80','DIÁRIO','0,031234','10','%'],
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

test('plastic without unit is refused',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo','Taxa','Plástico (Empresa)'],
  ['HOPE','Gov. AC','Cartão','Novo','84','1.8','50'],
 ],ctx)
 assert.ok(r.issues.some(x=>x.code==='component_unit_required'))
})

test('zero deferred is ignored and does not trigger question',()=>{
 const r=mapSmartCommercialRows([
  ['Banco','Convênio','Produto','Tipo de Contrato','Prazo','Taxa','Diferido (Empresa)'],
  ['HOPE','Gov. AC','Tabela 001','Novo','84','1.8','0'],
 ],ctx)
 assert.equal(r.summary.hasDeferred,false)
 assert.equal(r.issues.length,0)
})
