import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { SITUATIONS, SITUATION_LABEL, contractSituation, matchesSituation, paidByEvidence, situationFilter, situationLabel, situationOptions, type Situation } from '../../src/lib/contractStatus'
import { caseStateLabel, proposalStatusLabel } from '../../src/lib/operational'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')

test('one contract reads the same in the Esteira and in Contratos', () => {
  // Created as "Aguardando digitação": proposal status digitization, case digitization_queue.
  assert.equal(contractSituation('digitization', 'digitization_queue'), 'digitization_queue')
  assert.equal(situationLabel(contractSituation('digitization', 'digitization_queue')), 'Aguardando digitação')
  assert.equal(caseStateLabel('digitization_queue').label, 'Aguardando digitação')
  assert.equal(proposalStatusLabel('digitization', 'digitization_queue').label, 'Aguardando digitação')
  // Moved to "Em digitação": the proposal status stays digitization, the case says digitizing.
  assert.equal(proposalStatusLabel('digitization', 'digitizing').label, 'Em digitação')
  // Pendência: proposal submitted, case pending_external.
  assert.equal(contractSituation('submitted', 'pending_external'), 'pending_external')
  // Without a case (before the queue) the proposal status decides.
  assert.equal(contractSituation('draft', null), 'draft')
  assert.equal(contractSituation('digitization', null), 'digitization_queue')
  assert.equal(contractSituation('zzz', null), null)
  assert.equal(situationLabel(null), 'Situação desconhecida')
})

test('the company stage name wins, as in the Esteira', () => {
  assert.equal(situationLabel('submitted', { stageName: 'No banco' }), 'No banco')
  assert.equal(situationLabel('submitted', { stageName: '  ' }), 'Em análise no banco')
})

test('"confirmada por evidência" only when it came from a bank file', () => {
  assert.equal(situationLabel('paid'), 'Paga')
  assert.equal(situationLabel('paid', { paidSource: 'manual' }), 'Paga')
  assert.equal(situationLabel('paid', { paidSource: 'import' }), 'Paga (confirmada por evidência)')
  assert.equal(situationLabel('paid', { paidSource: 'commission_report' }), 'Paga (confirmada por evidência)')
  assert.equal(paidByEvidence(null), false)
  for (const s of SITUATIONS) if (s !== 'paid') assert.doesNotMatch(situationLabel(s, { paidSource: 'import' }), /evidência/, s)
})

test('the Situação filter offers each situation once, with distinct names', () => {
  const opts = situationOptions()
  assert.deepEqual(opts.map(o => o.value), [...SITUATIONS])
  assert.equal(new Set(opts.map(o => o.value)).size, opts.length)
  assert.equal(new Set(opts.map(o => o.label)).size, opts.length)
  assert.equal(new Set(Object.values(SITUATION_LABEL)).size, SITUATIONS.length)
  // A state with one company stage uses its name; with two stages (ambiguous) the shared name.
  const named = situationOptions([{ canonical_state: 'submitted', name: 'No banco' }, { canonical_state: 'approved', name: 'Aprovada A' }, { canonical_state: 'approved', name: 'Aprovada B' }])
  assert.equal(named.find(o => o.value === 'submitted')?.label, 'No banco')
  assert.equal(named.find(o => o.value === 'approved')?.label, 'Aprovada')
  // The old proposal-only value "digitization" is not an option any more.
  assert.ok(!opts.some(o => (o.value as string) === 'digitization'))
})

test('every filter option finds the contracts in that situation, and only those', () => {
  const contracts: { status: string; caseState: string | null; expect: Situation }[] = [
    { status: 'draft', caseState: null, expect: 'draft' },
    { status: 'documents_pending', caseState: null, expect: 'documents_pending' },
    { status: 'ready_for_digitization', caseState: null, expect: 'ready_for_digitization' },
    { status: 'digitization', caseState: 'digitization_queue', expect: 'digitization_queue' },
    { status: 'digitization', caseState: 'digitizing', expect: 'digitizing' },
    { status: 'submitted', caseState: 'submitted', expect: 'submitted' },
    { status: 'submitted', caseState: 'pending_external', expect: 'pending_external' },
    { status: 'approved', caseState: 'approved', expect: 'approved' },
    { status: 'paid', caseState: 'paid', expect: 'paid' },
    { status: 'rejected', caseState: 'rejected', expect: 'rejected' },
    { status: 'cancelled', caseState: null, expect: 'cancelled' },
  ]
  for (const o of situationOptions()) {
    const found = contracts.filter(c => matchesSituation(o.value, c.status, c.caseState))
    assert.deepEqual(found.map(c => c.expect), [o.value], o.value)
  }
  // No filter shows everything; an unknown value from the address is ignored.
  assert.equal(contracts.filter(c => matchesSituation('', c.status, c.caseState)).length, contracts.length)
  assert.equal(situationFilter('digitization'), '')
  assert.equal(situationFilter('<script>'), '')
  assert.equal(situationFilter('paid'), 'paid')
})

test('screens use the shared names, not their own copies', () => {
  for (const f of ['src/app/app/contratos/page.tsx', 'src/app/app/propostas/[id]/page.tsx', 'src/app/app/propostas/[id]/HistoryCard.tsx', 'src/app/app/propostas/PreQueue.tsx']) {
    const src = read(f)
    assert.match(src, /@\/lib\/contractStatus|@\/lib\/operational/, f)
    assert.doesNotMatch(src, /'Pago ao cliente'|'Aguardando digitação'|'Em digitação'/, f)
  }
})
