import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ageOn, dateBr, missingProfileFields } from '../../src/lib/clients/profile'

test('client profile: missing fields are listed, nothing required blocks', () => {
  const none = missingProfileFields({}, { hasBankAccount: false, hasRegistration: false })
  assert.ok(none.includes('data de nascimento') && none.includes('nome da mãe') && none.includes('dados bancários') && none.includes('matrícula'))
  const full = missingProfileFields({ birth_date: '1980-05-17', father_name: 'a', mother_name: 'b', rg_number: '1', rg_issuer: 'SSP', rg_state: 'AC', rg_issued_on: '2000-01-01',
    gender: 'F', marital_status: 'married', birthplace_city: 'Rio Branco', birthplace_state: 'AC', whatsapp: '5568999887766' }, { hasBankAccount: true, hasRegistration: true })
  assert.deepEqual(full, [])
})
test('client profile: age counts whole years, birthday not reached yet', () => {
  assert.equal(ageOn('1980-05-17', '2026-05-16'), 45)
  assert.equal(ageOn('1980-05-17', '2026-05-17'), 46)
  assert.equal(ageOn('2000-02-29', '2026-02-28'), 25)
})
test('client profile: dates shown as dd/mm/yyyy without time zone shift', () => {
  assert.equal(dateBr('1980-05-17'), '17/05/1980')
  assert.equal(dateBr(null), '—')
})
