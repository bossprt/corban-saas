import test from 'node:test'
import assert from 'node:assert/strict'
import { addDaysISO, currentMonthSP, currentYearSP, formatDateSP, formatDateTimeSP, monthStartSP, nowLocalSP, todaySP } from '../../src/lib/dates'

// 06/11/2026 23:30 em Brasília = 07/11/2026 02:30 UTC (servidor da Vercel já está no dia seguinte).
const lateNight = new Date('2026-11-07T02:30:00Z')
// Último dia do mês, 22h em Brasília = 01/12 01:00 UTC.
const lastOfMonth = new Date('2026-12-01T01:00:00Z')
// Último dia do ano, 23:59 em Brasília = 01/01/2027 02:59 UTC.
const lastOfYear = new Date('2027-01-01T02:59:00Z')

test('dates: 23:30 em Brasília ainda é hoje, não amanhã', () => {
  assert.equal(todaySP(lateNight), '2026-11-06')
  assert.equal(nowLocalSP(lateNight), '2026-11-06T23:30')
  assert.equal(formatDateTimeSP(lateNight), '06/11/2026, 23:30:00')
  assert.equal(formatDateTimeSP('2026-11-07T02:30:00Z', { dateStyle: 'short', timeStyle: 'short' }), '06/11/2026, 23:30')
  assert.equal(formatDateSP(lateNight), '06/11/2026')
  assert.equal(formatDateSP('2026-11-07T02:30:00+00:00'), '06/11/2026')
})

test('dates: último dia do mês à noite continua no mês atual', () => {
  assert.equal(todaySP(lastOfMonth), '2026-11-30')
  assert.equal(currentMonthSP(lastOfMonth), '2026-11')
  assert.equal(monthStartSP(lastOfMonth), '2026-11-01')
})

test('dates: 31/12 à noite continua no ano atual', () => {
  assert.equal(todaySP(lastOfYear), '2026-12-31')
  assert.equal(currentYearSP(lastOfYear), 2026)
  assert.equal(currentMonthSP(lastOfYear), '2026-12')
  assert.equal(nowLocalSP(lastOfYear), '2026-12-31T23:59')
})

test('dates: meia-noite em Brasília vira o dia', () => {
  assert.equal(todaySP(new Date('2026-11-07T03:00:00Z')), '2026-11-07')
  assert.equal(nowLocalSP(new Date('2026-11-07T03:00:00Z')), '2026-11-07T00:00')
})

test('dates: data pura não muda de dia com o fuso', () => {
  assert.equal(formatDateSP('2026-11-06'), '06/11/2026')
  assert.equal(formatDateSP('1980-01-01'), '01/01/1980')
  assert.equal(formatDateSP('2026-11-06', { weekday: 'long', day: 'numeric', month: 'long' }), 'sexta-feira, 6 de novembro')
})

test('dates: addDaysISO atravessa mês e ano', () => {
  assert.equal(addDaysISO('2026-11-30', 1), '2026-12-01')
  assert.equal(addDaysISO('2026-12-31', 1), '2027-01-01')
  assert.equal(addDaysISO('2026-03-01', -1), '2026-02-28')
  assert.equal(addDaysISO('2026-11-06T23:00:00Z', 0), '2026-11-06')
})
