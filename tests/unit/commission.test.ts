import test from 'node:test'
import assert from 'node:assert/strict'
import { calculateExpectedCommission,ComponentInput } from '../../src/lib/commission/engine'
import { fromDecimalString,toDecimalString,add,mul,div } from '../../src/lib/commission/money'

const c=(o:Partial<ComponentInput>={}):ComponentInput=>({componentType:'upfront',fixedAmount:null,grossPercentage:'2.5',anticipationFactor:null,upstreamShare:'1',...o})

test('float traps are exact: 0.1+0.2 = 0.3 and 1.005 rounds half up to 1.01',()=>{
 assert.equal(toDecimalString(add(fromDecimalString('0.1'),fromDecimalString('0.2')),2),'0.30')
 assert.equal(toDecimalString(fromDecimalString('1.005'),2),'1.01')
 assert.equal(toDecimalString(mul(fromDecimalString('19.99'),fromDecimalString('3')),2),'59.97')
 assert.equal(toDecimalString(div(fromDecimalString('1'),fromDecimalString('3')),4),'0.3333')
})

test('percentage of base, 100/0 and 95/5 splits always sum back to gross',()=>{
 assert.deepEqual(calculateExpectedCommission('10000',[c()]),[{componentType:'upfront',gross:'250.00',tenant:'250.00',downstream:'0.00'}])
 const [r]=calculateExpectedCommission('10000',[c({upstreamShare:'0.95'})])
 assert.deepEqual([r.gross,r.tenant,r.downstream],['250.00','237.50','12.50'])
 const [odd]=calculateExpectedCommission('333.33',[c({grossPercentage:'3',upstreamShare:'0.9'})],6)
 assert.equal(toDecimalString(add(fromDecimalString(odd.tenant),fromDecimalString(odd.downstream)),6),odd.gross)
})

test('fixed amount wins over percentage; anticipation factor scales only anticipation',()=>{
 assert.equal(calculateExpectedCommission('10000',[c({fixedAmount:'80',grossPercentage:'50'})])[0].gross,'80.00')
 assert.equal(calculateExpectedCommission('10000',[c({componentType:'deferred_anticipation',grossPercentage:'4',anticipationFactor:'0.75'})])[0].gross,'300.00')
 assert.equal(calculateExpectedCommission('10000',[c({componentType:'deferred',grossPercentage:'4',anticipationFactor:'0.75'})])[0].gross,'400.00')
})

test('zero commission is a real component; blank/unknown is an error (zero != blank)',()=>{
 const [z]=calculateExpectedCommission('10000',[c({grossPercentage:'0'})])
 assert.equal(z.gross,'0.00')
 assert.throws(()=>calculateExpectedCommission('10000',[c({grossPercentage:null,fixedAmount:null})]),/component_value_required/)
 assert.throws(()=>calculateExpectedCommission('10000',[c({componentType:'deferred_anticipation',anticipationFactor:null})]),/anticipation_factor_required/)
})

test('invalid inputs fail closed',()=>{
 assert.throws(()=>calculateExpectedCommission('-1',[c()]),/snapshot_calculation_base_required/)
 assert.throws(()=>calculateExpectedCommission('10',[]),/per_component_snapshot_required/)
 assert.throws(()=>calculateExpectedCommission('10',[c({upstreamShare:'1.2'})]),/invalid_share/)
 assert.throws(()=>calculateExpectedCommission('10',[c({grossPercentage:'1e3'})]),/invalid_decimal/)
 assert.throws(()=>calculateExpectedCommission('abc',[c()]),/invalid_decimal/)
})

test('golden vectors cross-checked against Postgres numeric (verified on the live DB, read-only SELECT)',()=>{
 const r1=calculateExpectedCommission('333.33',[c({grossPercentage:'3',upstreamShare:'0.9'})],6)[0]
 assert.deepEqual([r1.gross,r1.tenant,r1.downstream],['9.999900','8.999910','0.999990'])
 const r2=calculateExpectedCommission('12345.67',[c({componentType:'deferred_anticipation',grossPercentage:'4.75',anticipationFactor:'0.8137',upstreamShare:'0.95'})],6)[0]
 assert.deepEqual([r2.gross,r2.tenant,r2.downstream],['477.169405','453.310935','23.858470'])
 const r3=calculateExpectedCommission('999.99',[c({fixedAmount:'12.345',grossPercentage:'9',upstreamShare:'0.5'})],6)[0]
 assert.deepEqual([r3.gross,r3.tenant,r3.downstream],['12.345000','6.172500','6.172500'])
})
