import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { addressSource, allowLookup, applyLookup, EMPTY_ADDRESS, formatCep, normalizeCep, parseViaCep, type AddressKey } from '../../src/lib/cep'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')

test('CEP: mask and spaces accepted, exactly 8 digits required', () => {
  for (const [i, o] of [['69900000', '69900000'], ['69.900-000', '69900000'], [' 69900-000 ', '69900000'], ['01310100', '01310100']] as const) assert.equal(normalizeCep(i), o)
  for (const bad of ['', '1234567', '123456789', 'abcdefgh', '6990000a', null, undefined, 69900000.5, '69900 000 1']) assert.equal(normalizeCep(bad), null, String(bad))
  assert.equal(formatCep('69900000'), '69900-000')
})
test('ViaCEP answers: found, unknown, malformed, garbage and outage are all told apart; nothing is guessed', () => {
  const ok = { cep: '01310-100', logradouro: 'Avenida Paulista', complemento: 'de 612 a 1510 - lado par', bairro: 'Bela Vista', localidade: 'São Paulo', uf: 'sp' }
  assert.deepEqual(parseViaCep(200, ok), { kind: 'found', address: { street: 'Avenida Paulista', district: 'Bela Vista', city: 'São Paulo', state: 'SP', complement: 'de 612 a 1510 - lado par' } })
  assert.deepEqual(parseViaCep(200, { erro: true }), { kind: 'not_found' })
  assert.deepEqual(parseViaCep(200, { erro: 'true' }), { kind: 'not_found' })
  assert.deepEqual(parseViaCep(400, null), { kind: 'invalid' })
  for (const [s, b] of [[500, {}], [200, null], [200, 'x'], [200, { localidade: 'X' }], [200, { uf: 'SP' }], [200, { uf: 'SPX', localidade: 'X' }], [503, ok]] as const) assert.deepEqual(parseViaCep(s, b), { kind: 'unavailable' }, JSON.stringify([s, b]))
  const dirty = parseViaCep(200, { uf: 'ac', localidade: 'Rio\u0000 Branco', logradouro: '  Rua\n X  ', bairro: 5 })
  assert.equal(dirty.kind === 'found' && dirty.address.city, 'Rio Branco')
  assert.equal(dirty.kind === 'found' && dirty.address.street, 'Rua X')
  assert.equal(dirty.kind === 'found' && dirty.address.district, '')
})
const found = { street: 'Rua A', district: 'Centro', city: 'Rio Branco', state: 'AC', complement: '' }
test('lookup never overwrites what the person typed; it fills empty fields; number stays manual', () => {
  const empty = applyLookup(EMPTY_ADDRESS, new Set(), found)
  assert.deepEqual([empty.street, empty.district, empty.city, empty.state, empty.number], ['Rua A', 'Centro', 'Rio Branco', 'AC', ''])
  const typed = { ...EMPTY_ADDRESS, street: 'Rua do Cliente', number: '12' }
  const touched = new Set<AddressKey>(['street', 'number'])
  const r = applyLookup(typed, touched, found)
  assert.equal(r.street, 'Rua do Cliente')
  assert.equal(r.number, '12')
  assert.equal(r.city, 'Rio Branco')
  // typed then erased: the field is empty again, so it may be filled
  assert.equal(applyLookup({ ...EMPTY_ADDRESS, street: '' }, new Set<AddressKey>(['street']), found).street, 'Rua A')
})
test('address source records provenance', () => {
  assert.equal(addressSource(false, new Set()), 'manual')
  assert.equal(addressSource(true, new Set()), 'cep_lookup')
  assert.equal(addressSource(true, new Set<AddressKey>(['number', 'complement'])), 'cep_lookup') // manual number/complement do not make the lookup "edited"
  assert.equal(addressSource(true, new Set<AddressKey>(['street'])), 'cep_lookup_edited')
})
test('lookup throttle allows 30 per minute per user and forgets old hits', () => {
  const hits = new Map<string, number[]>()
  for (let i = 0; i < 30; i++) assert.equal(allowLookup(hits, 'u', 1000 + i), true)
  assert.equal(allowLookup(hits, 'u', 1100), false)
  assert.equal(allowLookup(hits, 'other', 1100), true)
  assert.equal(allowLookup(hits, 'u', 1000 + 61_000), true)
})
test('CEP route and forms: authenticated, key-less, fixed upstream host, timeout, never blocks the save', () => {
  const route = read('src/app/api/cep/route.ts')
  assert.ok(/auth\.getUser\(\)/.test(route) && /401/.test(route))
  assert.ok(/https:\/\/viacep\.com\.br\/ws\/\$\{cep\}\/json\//.test(route)) // host is fixed; only the validated 8 digits are interpolated
  assert.ok(/AbortController/.test(route) && !/process\.env/.test(route))
  const act = read('src/app/app/clientes/actions.ts')
  assert.ok(/ok:cliente_endereco_pendente/.test(act))
  assert.ok(!/formData\.get\('organization/.test(act)) // tenant never comes from the form
  const comp = read('src/components/AddressFields.tsx')
  assert.ok(/name=\{`\$\{prefix\}number`\}/.test(comp) && !/required/.test(comp))
})
test('address is stored in the EXISTING customer_addresses table (composite tenant FK + member RLS already LIVE): no new table, no duplicate model', () => {
  const act = read('src/app/app/clientes/actions.ts')
  assert.ok(act.includes("from('customer_addresses')") && act.includes('is_primary: true'))
  assert.ok(!act.includes('client_addresses') && !existsSync(join(process.cwd(), 'supabase/migrations/20261003_customer_address_v1.sql')))
  assert.ok(act.includes('organization_id: organizationId')) // active tenant from the server context, never from the form
})

import { onboardingSteps } from '../../src/lib/commercial'
test('onboarding: computed from real counts, one clear next step, order follows the business flow', () => {
  const zero = onboardingSteps({ banks: 0, agreements: 0, groups: 0, tables: 0, draftConditions: 0, publishedVersions: 0 })
  assert.deepEqual(zero.steps.map(s => s.key), ['bank', 'agreement', 'group', 'table', 'condition', 'publish'])
  assert.equal(zero.next?.key, 'bank')
  assert.equal(onboardingSteps({ banks: 1, agreements: 1, groups: 0, tables: 0, draftConditions: 0, publishedVersions: 0 }).next?.key, 'group')
  assert.equal(onboardingSteps({ banks: 1, agreements: 1, groups: 2, tables: 1, draftConditions: 3, publishedVersions: 0 }).next?.key, 'publish')
  assert.equal(onboardingSteps({ banks: 1, agreements: 1, groups: 2, tables: 1, draftConditions: 0, publishedVersions: 1 }).next, null)
  assert.ok(zero.steps.every(s => s.hint.length > 10 && !/tech_key|código técnico/i.test(s.hint)))
})
