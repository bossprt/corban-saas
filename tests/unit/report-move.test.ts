import { test } from 'node:test'
import assert from 'node:assert/strict'
import { reportMove } from '../../src/lib/imports/report-move'

// The bank's report moves a contract already in Corban only forward (owner, 20/10/2026).
test('report move: forward only, paid never changes', () => {
  assert.equal(reportMove('submitted', 'paid'), 'move')
  assert.equal(reportMove('digitization_queue', 'submitted'), 'move')
  assert.equal(reportMove('submitted', 'pending_external'), 'move')
  assert.equal(reportMove('pending_external', 'submitted'), 'move')
  assert.equal(reportMove('approved', 'submitted'), 'never')
  assert.equal(reportMove('paid', 'paid'), 'same')
  assert.equal(reportMove('paid', 'submitted'), 'never')
  assert.equal(reportMove('paid', 'cancelled'), 'paid_conflict')
  assert.equal(reportMove('submitted', 'cancelled'), 'move')
  assert.equal(reportMove('cancelled', 'paid'), 'never')
  assert.equal(reportMove('rejected', 'submitted'), 'never')
})
