// Legacy base (F5.5): the fields of the previous system's export and the issue labels. No I/O: shared by the import
// screen (browser) and the server.
import { normalizeHeader } from '../commercial'

export type LegacyField = 'cpf' | 'full_name' | 'phone' | 'bank_name' | 'agreement_name' | 'contract_type' | 'ade' | 'contract_number' | 'legacy_ref' | 'contract_on' | 'paid_on'
  | 'requested_amount' | 'released_amount' | 'installment_amount' | 'term' | 'seller_name' | 'status_text'
export type LegacyMapping = Partial<Record<LegacyField, string>>
export type LegacyRow = { row: number } & Partial<Record<LegacyField, string>>

export const LEGACY_FIELDS: { key: LegacyField; label: string; required?: boolean; aliases: string[] }[] = [
  { key: 'cpf', label: 'CPF do cliente', required: true, aliases: ['cpf', 'cpf_cliente', 'cpf_do_cliente', 'documento', 'cpfcliente'] },
  { key: 'full_name', label: 'Nome do cliente', aliases: ['nome', 'cliente', 'nome_cliente', 'nome_do_cliente', 'nomecliente'] },
  { key: 'phone', label: 'Telefone', aliases: ['telefone', 'celular', 'fone', 'telefone_celular', 'whatsapp', 'telefonecliente'] },
  { key: 'bank_name', label: 'Banco', aliases: ['banco', 'instituicao', 'banco_origem'] },
  { key: 'agreement_name', label: 'Convênio', aliases: ['convenio', 'orgao', 'empregador'] },
  { key: 'contract_type', label: 'Tipo de contrato / produto', aliases: ['tipo', 'tipo_de_contrato', 'produto', 'operacao', 'tipo_operacao', 'tipocontrato'] },
  { key: 'ade', label: 'Nº da proposta no banco (ADE)', aliases: ['ade', 'proposta', 'numero_da_proposta', 'num_proposta', 'numeroproposta'] },
  { key: 'contract_number', label: 'Nº do contrato no banco', aliases: ['contrato', 'numero_contrato', 'n_contrato', 'numerocontrato'] },
  { key: 'legacy_ref', label: 'Código no sistema antigo', aliases: ['codigo', 'id', 'contratoid', 'id_contrato', 'codigo_contrato'] },
  { key: 'contract_on', label: 'Data do contrato', aliases: ['data', 'data_contrato', 'data_do_contrato', 'data_digitacao', 'data_cadastro', 'datacontrato'] },
  { key: 'paid_on', label: 'Data do pagamento ao cliente', aliases: ['data_pagamento', 'pago_em', 'data_de_pagamento', 'data_pgto'] },
  { key: 'requested_amount', label: 'Valor do contrato (bruto)', aliases: ['valor', 'valor_contrato', 'valor_bruto', 'valor_solicitado', 'valor_operacao', 'valorbruto'] },
  { key: 'released_amount', label: 'Valor liberado (líquido)', aliases: ['valor_liberado', 'valor_liquido', 'liquido', 'valorliquido'] },
  { key: 'installment_amount', label: 'Parcela', aliases: ['parcela', 'valor_parcela', 'valor_da_parcela', 'valorparcela'] },
  { key: 'term', label: 'Prazo (meses)', aliases: ['prazo', 'prazo_meses', 'qtd_parcelas', 'parcelas'] },
  { key: 'seller_name', label: 'Vendedor / corretor', aliases: ['vendedor', 'corretor', 'agente', 'digitador', 'nomecorretor'] },
  { key: 'status_text', label: 'Situação no sistema antigo', aliases: ['status', 'situacao', 'statusproposta'] },
]

export const LEGACY_ISSUE_LABEL: Record<string, string> = {
  invalid_cpf: 'CPF inválido',
  full_name_required: 'Cliente novo sem nome',
  invalid_value: 'Valor ou prazo inválido',
  invalid_date: 'Data inválida ou no futuro',
  after_cutoff: 'Contrato depois da data de corte (entra pela esteira)',
  already_in_corban: 'Contrato já está no Corban',
  duplicate_contract: 'Contrato repetido',
}

export const LEGACY_STATUS: Record<string, { label: string; tone: 'pending' | 'received' | 'neutral' | 'reversed' }> = {
  draft: { label: 'Em conferência', tone: 'pending' }, confirmed: { label: 'Importado', tone: 'received' },
  undone: { label: 'Desfeito', tone: 'reversed' }, discarded: { label: 'Descartado', tone: 'neutral' },
}

// Pre-selects each field whose column name is an obvious alias; a column is used once.
export function guessLegacyMapping(headers: string[]): LegacyMapping {
  const norm = headers.map(normalizeHeader)
  const used = new Set<number>()
  const out: LegacyMapping = {}
  for (const f of LEGACY_FIELDS) {
    const i = norm.findIndex((h, j) => !used.has(j) && f.aliases.includes(h))
    if (i >= 0) { out[f.key] = headers[i]; used.add(i) }
  }
  return out
}
