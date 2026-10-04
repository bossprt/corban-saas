import test from 'node:test'
import assert from 'node:assert/strict'
import { CONTRACT_LAYOUTS, mapContractHeader, matchTable, parseContractLine, parseContractSheet } from '../../src/lib/imports/contract-layout'
import { csvRows } from '../../src/lib/imports/csv'

// A valid CPF built for tests (no real person): 529.982.247-25.
const CPF = '52998224725'
const TODAY = '2026-10-02'
const HEAD = ['CPF *', 'Nome', 'Tabela *', 'Prazo (meses) *', 'Valor liberado', 'Nº contrato/ADE', 'Etapa', 'Pago ao cliente em']

test('template header maps every column; nothing missing', () => {
  const m = mapContractHeader(HEAD)
  assert.deepEqual(m.issues, [])
  assert.deepEqual(m.columns.cpf, [0])
  assert.deepEqual(m.columns.ade, [5])
  assert.deepEqual(m.columns.paidOn, [7])
})

test('a sheet without optional columns is accepted (owner rule)', () => {
  const m = mapContractHeader(['CPF', 'Tabela', 'Prazo', 'Valor solicitado'])
  assert.deepEqual(m.issues, [])
})

test('missing identification columns refuse the file', () => {
  const codes = mapContractHeader(['Nome', 'Valor da parcela']).issues.map(i => i.column)
  assert.deepEqual(codes, ['CPF', 'Tabela', 'Prazo (meses)', 'Valor liberado ou Valor solicitado'])
})

test('unknown money columns refuse the file; unknown text columns are only listed', () => {
  const m = mapContractHeader([...HEAD, 'Valor comissão', 'Cargo'])
  assert.deepEqual(m.issues, [{ code: 'unknown_money_column', column: 'Valor comissão' }])
  assert.deepEqual(m.ignored, ['Cargo'])
})

test('line: Excel number CPF without leading zero, money and Brazilian date', () => {
  const { columns } = mapContractHeader(HEAD)
  const l = parseContractLine(['1234567890', 'Teste', 'Temporário (8 a 18 meses)', '12', '1.500,50', '0099', 'paga', '01/10/2026'], columns, 2, TODAY)
  assert.equal(l.cpf, '01234567890')
  assert.equal(l.released, '1500.50')
  assert.equal(l.stage, 'paid')
  assert.equal(l.paidOn, '2026-10-01')
  assert.equal(l.ade, '0099')
})

test('line issues: invalid CPF, no amount, future paid date, paid without date', () => {
  const { columns } = mapContractHeader(HEAD)
  assert.deepEqual(parseContractLine(['11111111111', '', 'T', '12', '', '', '', ''], columns, 2, TODAY).issues, ['cpf_invalid', 'amount_required'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '12', '10', '', 'paga', '03/10/2026'], columns, 2, TODAY).issues, ['paid_on_invalid'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '12', '10', '', 'paga', ''], columns, 2, TODAY).issues, ['paid_on_required'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '0', '10', '', 'xpto', ''], columns, 2, TODAY).issues, ['term_invalid', 'stage_unknown'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '12', '1.5.0', '', '', ''], columns, 2, TODAY).issues, ['amount_invalid'])
})

test('sheet: blank header issues stop before lines; lines numbered as in Excel', () => {
  const s = parseContractSheet([HEAD, [CPF, 'A', 'T', '12', '100', '', '', '']], TODAY)
  assert.equal(s.lines[0].line, 2)
  assert.equal(parseContractSheet([['Nome']], TODAY).lines.length, 0)
})

test('table match: exact, by the end of the bank name, ambiguous, none', () => {
  const tables = [
    { name: 'NASP - Gov. Acre - Temporário (4 a 7 meses)' },
    { name: 'NASP - Gov. Acre - Temporário (8 a 18 meses)' },
    { name: 'NASP - Gov. Acre - COMPRA NORMAL' },
    { name: 'NASP - Pref. X - COMPRA NORMAL' },
  ]
  assert.equal(matchTable('temporario (8 a 18 meses)', tables), tables[1])
  assert.equal(matchTable('NASP - Gov. Acre - COMPRA NORMAL', tables), tables[2])
  assert.equal(matchTable('COMPRA NORMAL', tables), 'ambiguous')
  assert.equal(matchTable('Legado', tables), 'none')
})

test('table match: the Governo do Acre name and the Prefeitura name of the same bank stay apart', () => {
  const tables = [
    { name: 'NASP - Gov. Acre - Temporário (4 a 7 meses)' },
    { name: 'NASP - Pref. Rio Branco - Prefeitura Temporário (4 a 7 meses)' },
    { name: 'NASP - Gov. Acre - Normal - Efetivo / Pensionista' },
  ]
  assert.equal(matchTable('Temporário (4 a 7 meses)', tables), tables[0])
  assert.equal(matchTable('Prefeitura Temporário (4 a 7 meses)', tables), tables[1])
  assert.equal(matchTable('Normal - Efetivo / Pensionista', tables), tables[2])
})

// The NASP export header as the bank sends it (column names only; every value below is made up).
const NASP_HEADER = 'Data do pagamento;Forma de pagamento;Nº proposta;ADE;Tipo;Operação;Origem;Fase;Situação;Data do contrato;Data da liberação;Data 1ª parcela;Data última parcela;Qtd parcelas;Valor da parcela;Valor final;Valor bruto liberado;Valor líquido pago;Saldo por dentro (refin);Quitação externa (compra dívida);Taxa juros mensal (%);CET a.m. (%);CET a.a. (%);IOF;Observações do contrato;Convênio;Tabela;Recurso financeiro;Parceiro;Agente;Matrícula;Categoria servidor;Secretaria;Lotação;Cargo;Salário;Regime de contratação;Data de admissão;Cliente;CPF;Data de nascimento;Sexo;Estado civil;Nacionalidade;Naturalidade;Escolaridade;RG;RG órgão emissor;RG UF;RG data expedição;PIS;Nome da mãe;Nome do pai;Cônjuge;Telefone cônjuge;Pessoa exposta politicamente;Analfabeto;Telefone;Celular;WhatsApp;E-mail;Logradouro;Número;Complemento;Bairro;Cidade;UF;CEP;Banco (código);Banco;Agência;Dígito agência;Conta;Dígito conta;Tipo de conta;Titular da conta;CPF do titular;Tipo chave PIX;Chave PIX;Comissão base;Comissão %;Comissão valor;Comissão status;Mensalidade (contrato);Mensalidade ADE;Mensalidade data averbação;Mensalidade valor da ADE;Mensalidade valor anterior;Mensalidade valor líquido (diferença);Mensalidade é migração'
const NASP_ROW: Record<string, string> = {
  'Data do pagamento': '02/10/2026', 'Nº proposta': '999', ADE: '7000001', Tipo: 'emprestimo', 'Operação': 'novo', Fase: 'credito_liberado',
  'Situação': 'ativo', 'Data da liberação': '02/10/2026', 'Qtd parcelas': '15', 'Valor da parcela': '100,50', 'Valor final': '1507,5',
  'Valor bruto liberado': '1000', 'Valor líquido pago': '1000', 'Saldo por dentro (refin)': '0', 'Convênio': 'Governo do Estado do Acre',
  Tabela: 'Temporário (8 a 18 meses)', Agente: 'Vendedor Teste', 'Matrícula': '123456789', Secretaria: 'SECRETARIA TESTE', Cliente: 'CLIENTE FICTICIO',
  CPF: CPF, 'Data de nascimento': '15/09/2000', Sexo: 'masculino', 'Estado civil': 'solteiro(a)', Naturalidade: 'MANCIO LIMA - AC',
  RG: '1234567', 'RG órgão emissor': 'SSP', 'RG UF': 'ac', 'RG data expedição': '07/02/2017', 'Nome da mãe': 'MAE FICTICIA', 'Nome do pai': 'PAI FICTICIO',
  Telefone: '', Celular: '68 99999-0000', WhatsApp: '68 99999-0000', 'E-mail': 'Teste@Exemplo.com', Logradouro: 'RUA TESTE', 'Número': '10',
  Bairro: 'CENTRO', Cidade: 'Rio Branco', UF: 'AC', CEP: '69900-000', 'Banco (código)': '1', Banco: 'Banco do Brasil S.A.', 'Agência': '1234',
  'Dígito agência': '9', Conta: '5678', 'Dígito conta': 'x', 'Tipo de conta': 'corrente', 'Comissão valor': '100', 'Mensalidade valor da ADE': '50',
}
const naspSheet = () => {
  const head = NASP_HEADER.split(';')
  return [head, head.map(h => NASP_ROW[h] ?? '')]
}

test('NASP layout reads the bank export as it comes: no refusal, known money columns ignored on purpose', () => {
  const nasp = CONTRACT_LAYOUTS.find(l => l.key === 'nasp')!
  const m = mapContractHeader(NASP_HEADER.split(';'), nasp)
  assert.deepEqual(m.issues, [])
  for (const c of ['Comissão valor', 'Valor final', 'IOF', 'Mensalidade valor da ADE', 'Nº proposta', 'Data do pagamento']) assert.ok(m.ignored.includes(c), c)
  // Without the layout the same file is refused (two type columns, unknown money columns).
  assert.ok(mapContractHeader(NASP_HEADER.split(';')).issues.length > 0)
})

test('NASP line: contract fields and the client record', () => {
  const nasp = CONTRACT_LAYOUTS.find(l => l.key === 'nasp')!
  const { lines, map } = parseContractSheet(naspSheet(), TODAY, nasp)
  assert.deepEqual(map.issues, [])
  const l = lines[0]
  assert.deepEqual(l.issues, [])
  assert.equal(l.term, 15)
  assert.equal(l.released, '1000.00')
  assert.equal(l.requested, '1000.00')
  assert.equal(l.installment, '100.50')
  assert.equal(l.outstanding, null)
  assert.equal(l.ade, '7000001')
  assert.equal(l.typeKey, 'novo')
  assert.equal(l.stage, 'paid')
  assert.equal(l.paidOn, '2026-10-02')
  assert.equal(l.seller, 'Vendedor Teste')
  assert.equal(l.phone, '68 99999-0000')
  assert.equal(l.email, 'teste@exemplo.com')
  assert.deepEqual(l.client.profile, {
    birth_date: '2000-09-15', mother_name: 'MAE FICTICIA', father_name: 'PAI FICTICIO', rg_number: '1234567', rg_issuer: 'SSP', rg_state: 'AC',
    rg_issued_on: '2017-02-07', gender: 'M', marital_status: 'single', birthplace_city: 'MANCIO LIMA', birthplace_state: 'AC', whatsapp: '5568999990000',
  })
  assert.deepEqual(l.client.address, { postal_code: '69900000', street: 'RUA TESTE', number: '10', complement: null, neighborhood: 'CENTRO', city: 'Rio Branco', state: 'AC' })
  assert.deepEqual(l.client.account, { bank_code: '001', bank_name: 'Banco do Brasil S.A.', branch: '1234', account_number: '5678', account_digit: 'X', account_type: 'checking' })
  assert.deepEqual(l.client.registration, { number: '123456789', agency: 'SECRETARIA TESTE' })
  assert.deepEqual(l.warnings, [])
})

test('bad client values are skipped with a warning and never block the contract', () => {
  const nasp = CONTRACT_LAYOUTS.find(l => l.key === 'nasp')!
  const [head, row] = naspSheet()
  const set = (h: string, v: string) => { row[head.indexOf(h)] = v }
  set('Data de nascimento', '31/02/2000'); set('Sexo', 'x'); set('E-mail', 'sem-arroba'); set('CEP', '123')
  const l = parseContractSheet([head, row], TODAY, nasp).lines[0]
  assert.deepEqual(l.issues, [])
  assert.equal(l.client.profile.birth_date, undefined)
  assert.equal(l.client.address, null)
  assert.equal(l.warnings.length, 4)
})

test('csv: semicolon or comma, quotes, CRLF, Windows-1252', () => {
  assert.deepEqual(csvRows(new TextEncoder().encode('a;b;c\r\n1;"x;y";"di ""z"""\r\n\r\n')), [['a', 'b', 'c'], ['1', 'x;y', 'di "z"']])
  assert.deepEqual(csvRows(new TextEncoder().encode('a,b\n1,2\n')), [['a', 'b'], ['1', '2']])
  assert.deepEqual(csvRows(Uint8Array.from([0x4f, 0x70, 0x65, 0x72, 0x61, 0xe7, 0xe3, 0x6f])), [['Operação']])
})
