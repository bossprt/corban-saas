// Datas e horas sempre no horário de Brasília. A produção (Vercel) roda em UTC, 3 horas à frente:
// sem fuso explícito, depois das 21h "hoje" já seria amanhã e os horários sairiam adiantados.
// Sem dependência: só Intl com timeZone fixo. Funções puras; `now` é parâmetro para os testes.

export const TZ_SP = 'America/Sao_Paulo'

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/
const ymdFmt = new Intl.DateTimeFormat('en-CA', { timeZone: TZ_SP, year: 'numeric', month: '2-digit', day: '2-digit' })
const hmFmt = new Intl.DateTimeFormat('en-GB', { timeZone: TZ_SP, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })

/** Data de hoje em Brasília, 'YYYY-MM-DD'. */
export const todaySP = (now: Date = new Date()) => ymdFmt.format(now)
/** Mês atual em Brasília, 'YYYY-MM'. */
export const currentMonthSP = (now: Date = new Date()) => todaySP(now).slice(0, 7)
/** Primeiro dia do mês atual em Brasília, 'YYYY-MM-01'. */
export const monthStartSP = (now: Date = new Date()) => `${currentMonthSP(now)}-01`
/** Ano atual em Brasília. */
export const currentYearSP = (now: Date = new Date()) => Number(todaySP(now).slice(0, 4))
/** Agora em Brasília no formato do campo datetime-local, 'YYYY-MM-DDTHH:mm'. */
export const nowLocalSP = (now: Date = new Date()) => `${todaySP(now)}T${hmFmt.format(now)}`

/** Soma dias a uma data 'YYYY-MM-DD' (sem fuso: conta no calendário). */
export const addDaysISO = (iso: string, n: number) =>
  new Date(Date.parse(`${iso.slice(0, 10)}T12:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10)

/** Data e hora em Brasília, como toLocaleString('pt-BR'): '06/11/2026, 23:30:00'. */
export const formatDateTimeSP = (value: string | Date, opts: Intl.DateTimeFormatOptions = {}) =>
  new Date(value).toLocaleString('pt-BR', { ...opts, timeZone: TZ_SP })

/** Data em Brasília, 'dd/mm/aaaa'. Uma data pura 'YYYY-MM-DD' sai como está (não muda de dia com o fuso). */
export const formatDateSP = (value: string | Date, opts: Intl.DateTimeFormatOptions = {}) =>
  typeof value === 'string' && DATE_ONLY.test(value)
    ? new Date(`${value}T12:00:00Z`).toLocaleDateString('pt-BR', { ...opts, timeZone: 'UTC' })
    : new Date(value).toLocaleDateString('pt-BR', { ...opts, timeZone: TZ_SP })
