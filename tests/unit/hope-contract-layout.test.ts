import test from 'node:test'
import assert from 'node:assert/strict'
import { CONTRACT_LAYOUTS, parseContractSheet } from '../../src/lib/imports/contract-layout'

const hope = CONTRACT_LAYOUTS.find(l => l.key === 'hope')!
// The header of the Hope "BuscaContrato" report as exported (08/10/2026); the data row is made up.
const HEADER = ['ContratoId', 'NumeroProposta', 'NumeroContrato', 'UsuarioDigitacaoBanco', 'DataContrato', 'DataInclusao', 'NomeCliente', 'CpfCliente',
  'Bcvid', 'Banco', 'Convenio', 'Tabela', 'TipoContrato', 'Prazo', 'ValorBruto', 'ValorLiquido', 'ValorParcela', 'ValorBase', 'ValorBaseBonus',
  'MargemEmpresa', 'SpreadEmpresa', 'ComissaoEmpresaVistaPerc', 'ComissaoEmpresaVistaValor', 'BonusEmpresaPerc', 'BonusEmpresaValor', 'BonusRecebido',
  'DiferidoEmpresaPerc', 'DiferidoEmpresaValor', 'ComissaoRepassePercentual', 'ComissaoRepasseValor', 'BonusRepassePerc', 'BonusRepasseValor',
  'DiferidoRepassePerc', 'DiferidoRepasseValor', 'BaseCalculoComissao', 'BaseCalculoBonus', 'Filial', 'CodigoCorretor', 'NomeCorretor',
  'StatusBloqueioCorretor', 'SituacaoVendedor', 'FisicoEmpresa', 'DataFisico', 'HoraFisico', 'UsuarioFisicoEmpresa', 'FisicoBanco', 'DataFisicoBanco',
  'HoraFisicoBanco', 'UsuarioFisicoBanco', 'StatusBancoCliente', 'DataStatusBancoCliente', 'StatusEmpresaVendedor', 'DataStatusEmpresaVendedor',
  'StatusPendencia', 'ColecaoTags', 'StatusProposta', 'StatusFisicoUnico', 'ClientePossuiAnexo', 'QtdAnexoCliente', 'NomeGrupoVendedor',
  'TelefoneCliente', 'DescricaoComissionamento', 'VigenciaId', 'CorrespondenteId', 'NomeCorrespondente', 'Inclusão', 'Operador',
  ...[1, 2, 3, 4].flatMap(n => [`PercBonusEmpresa${n}`, `ValorBonusEmpresa${n}`]), ...[1, 2, 3, 4, 5].map(n => `EmpresaValorFixo${n}`),
  ...[1, 2, 3, 4].flatMap(n => [`PercBonusRepasse${n}`, `ValorBonusRepasse${n}`]), ...[1, 2, 3, 4, 5].map(n => `RepasseValorFixo${n}`)]
const row = (status: string, type = 'Contrato Novo', installment = '0') => {
  const v: Record<string, string> = {
    ContratoId: '1', NumeroProposta: '900001', NumeroContrato: '900001', NomeCliente: 'CLIENTE TESTE', CpfCliente: '529.982.247-25', Banco: 'HOPE',
    Convenio: 'Gov. AC', Tabela: 'EMPRÉSTIMO - GOV ACRE - 2.70%', TipoContrato: type, Prazo: '120', ValorBruto: '5147.21', ValorLiquido: '5147.21',
    ValorParcela: installment, ComissaoRepasseValor: '772.08', NomeCorretor: 'EMPRESA', StatusBancoCliente: status, DataStatusBancoCliente: '02/10/2026',
    TelefoneCliente: 'Dados não disponíveis',
  }
  return HEADER.map(h => v[h] ?? '0')
}

test('Hope report: every column is known, ADE from NumeroContrato, PAGO AO CLIENTE is paid on its date', () => {
  const r = parseContractSheet([HEADER, row('PAGO AO CLIENTE')], '2026-10-08', hope)
  assert.deepEqual(r.map.issues, [])
  const l = r.lines[0]
  assert.deepEqual(l.issues, [])
  assert.equal(l.ade, '900001')
  assert.equal(l.table, 'EMPRÉSTIMO - GOV ACRE - 2.70%')
  assert.equal(l.typeKey, 'novo')
  assert.equal(l.term, 120)
  assert.equal(l.requested, '5147.21')
  assert.equal(l.released, '5147.21')
  assert.equal(l.installment, null) // the report sends 0: not informed
  assert.equal(l.stage, 'paid')
  assert.equal(l.paidOn, '2026-10-02')
  assert.equal(l.seller, '')
  assert.equal(l.phone, '')
})

test('Hope report: an unknown status is never guessed; COMBO is refin + portability; a real installment is kept', () => {
  assert.ok(parseContractSheet([HEADER, row('EM ANALISE X')], '2026-10-08', hope).lines[0].issues.includes('stage_unknown'))
  const combo = parseContractSheet([HEADER, row('PAGO AO CLIENTE', 'COMBO', '150.00')], '2026-10-08', hope).lines[0]
  assert.equal(combo.typeKey, 'refin_portabilidade')
  assert.equal(combo.installment, '150.00')
})
