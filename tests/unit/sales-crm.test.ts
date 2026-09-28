import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildCampaignRows, chunk, guessCampaignMapping, localDateTimeToIso, MANUAL_STAGES, whatsappHref } from '../../src/lib/crm'

test('sales CRM: the header names of a campaign spreadsheet are recognized', () => {
  const m = guessCampaignMapping(['Nome do Cliente', 'CPF', 'Celular', 'Telefone 2', 'E-mail', 'Margem', 'Banco'])
  assert.deepEqual({ name: m.name, cpf: m.cpf, phone: m.phone, phone2: m.phone2, email: m.email }, { name: 0, cpf: 1, phone: 2, phone2: 3, email: 4 })
})

test('sales CRM: rows carry the mapped fields and the ticked columns as text', () => {
  const headers = ['Nome', 'CPF', 'Telefone', 'Margem', 'Banco']
  const rows = buildCampaignRows(headers, [
    ['Ana', '314.159.265-90', '(68) 99955-0002', '350,20', 'BB'],
    ['', '', '', '10,00', 'X'],           // no name, CPF or phone: left out
    ['  Bia  ', '', '68999550003', '', 'C6'],
  ], { name: 0, cpf: 1, phone: 2, info: [3, 4] })
  assert.equal(rows.length, 2)
  assert.deepEqual(rows[0], { name: 'Ana', cpf: '314.159.265-90', phone: '(68) 99955-0002', info: { Margem: '350,20', Banco: 'BB' } })
  assert.deepEqual(rows[1], { name: 'Bia', phone: '68999550003', info: { Banco: 'C6' } })
})

test('sales CRM: helpers', () => {
  assert.equal(whatsappHref('5568999550001'), 'https://wa.me/5568999550001')
  assert.equal(whatsappHref('(68) 99955-0001'), 'https://wa.me/5568999550001')
  assert.equal(whatsappHref('123'), null)
  assert.equal(localDateTimeToIso('2026-09-28T14:00'), '2026-09-28T17:00:00.000Z')
  assert.equal(localDateTimeToIso('amanhã'), null)
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  // "proposal" and "won" are never set by hand.
  assert.ok(!MANUAL_STAGES.includes('proposal') && !MANUAL_STAGES.includes('won'))
})
