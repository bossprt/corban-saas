import test from 'node:test'
import assert from 'node:assert/strict'
import { classifyTokenResponse } from '../../src/lib/bevicred'

test('bevicred token: success with a token is ok and the token is not returned', () => {
  const r = classifyTokenResponse(200, JSON.stringify({ success: true, message: null, contador: 1, dados: 'abc123' }), 120)
  assert.deepEqual(r, { ok: true, ms: 120 })
  assert.ok(!JSON.stringify(r).includes('abc123'))
})

test('bevicred token: success=false is rejected with the Bevicred message', () => {
  const r = classifyTokenResponse(200, JSON.stringify({ success: false, message: 'Usuario ou senha invalidos', dados: null }), 50)
  assert.equal(r.ok, false)
  assert.ok(!r.ok && r.reason === 'rejected' && r.detail === 'Usuario ou senha invalidos')
})

test('bevicred token: success without a token is not ok', () => {
  const r = classifyTokenResponse(200, JSON.stringify({ success: true, dados: '' }), 50)
  assert.ok(!r.ok && r.reason === 'rejected')
})

test('bevicred token: http errors and non-json answers', () => {
  assert.ok(((r) => !r.ok && r.reason === 'rejected')(classifyTokenResponse(401, '', 10)))
  assert.ok(((r) => !r.ok && r.reason === 'http' && r.detail === 'HTTP 500')(classifyTokenResponse(500, 'boom', 10)))
  assert.ok(((r) => !r.ok && r.reason === 'unexpected')(classifyTokenResponse(200, '<xml/>', 10)))
})

test('bevicred token: a long message is cut to one line of 200 characters', () => {
  const r = classifyTokenResponse(200, JSON.stringify({ success: false, message: 'x\n'.repeat(300) }), 10)
  assert.ok(!r.ok && (r.detail ?? '').length <= 200 && !(r.detail ?? '').includes('\n'))
})
