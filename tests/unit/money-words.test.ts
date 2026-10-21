import { test } from 'node:test'
import assert from 'node:assert/strict'
import { moneyInWords } from '../../src/lib/money-words'

test('money in words for printed statements', () => {
  assert.equal(moneyInWords('289.20'), 'duzentos e oitenta e nove reais e vinte centavos')
  assert.equal(moneyInWords('893.30'), 'oitocentos e noventa e três reais e trinta centavos')
  assert.equal(moneyInWords('1.00'), 'um real')
  assert.equal(moneyInWords('0.45'), 'quarenta e cinco centavos')
  assert.equal(moneyInWords('100'), 'cem reais')
  assert.equal(moneyInWords('1100.00'), 'mil e cem reais')
  assert.equal(moneyInWords('2030.01'), 'dois mil e trinta reais e um centavo')
  assert.equal(moneyInWords('15234.50'), 'quinze mil, duzentos e trinta e quatro reais e cinquenta centavos')
  assert.equal(moneyInWords('1000000'), 'um milhão de reais')
  assert.equal(moneyInWords('0'), 'zero real')
})
