import { NextResponse } from 'next/server'

// OpenAPI description of the public API v1.
const spec = {
  openapi: '3.1.0',
  info: { title: 'Corban API', version: '1.0.0', description: 'API pública do Corban. Cada chave pertence a uma empresa e é criada em Configurações > API.' },
  servers: [{ url: '/api/v1' }],
  components: {
    securitySchemes: { bearer: { type: 'http', scheme: 'bearer', description: 'Chave ck_live_… criada pelo administrador da empresa.' } },
    schemas: {
      LeadInput: {
        type: 'object',
        required: ['full_name'],
        properties: {
          full_name: { type: 'string', minLength: 2, maxLength: 200 },
          phone: { type: 'string', description: 'Telefone brasileiro com DDD. Obrigatório se não houver e-mail.' },
          email: { type: 'string', format: 'email' },
          cpf: { type: 'string', description: '11 dígitos, opcional. Usado para reconhecer um cliente existente.' },
          campaign: { type: 'string' },
          external_ref: { type: 'string', maxLength: 120, description: 'Seu identificador. Repetir o mesmo valor devolve o mesmo lead (idempotente).' },
          metadata: { type: 'object', description: 'Dados extras (ex.: qualificação BANT). Até 6 KB.' },
        },
      },
      LeadResult: {
        type: 'object',
        properties: { id: { type: 'string', format: 'uuid' }, status: { type: 'string' }, duplicate: { type: 'boolean' }, matched_client: { type: 'boolean' } },
      },
      Error: { type: 'object', properties: { error: { type: 'string' } } },
      Money: {
        oneOf: [{ type: 'string', pattern: '^[0-9]{1,9}(\\.[0-9]{1,2})?$' }, { type: 'number' }],
        description: 'Valor em reais com ponto decimal e até 2 casas ("5000.00" ou 5000.00). Lido como decimal exato. Sem separador de milhar.',
      },
      ContractInput: {
        type: 'object',
        required: ['external_id', 'sequencia', 'enviado_em', 'etapa', 'contrato', 'cliente'],
        properties: {
          external_id: { type: 'string', maxLength: 120, description: 'Seu identificador estável do contrato. Localiza o contrato no Corban; nunca muda.' },
          sequencia: { type: 'integer', minimum: 0, description: 'Número crescente por contrato. Uma chamada com sequencia menor ou igual à última aplicada não muda nada.' },
          enviado_em: { type: 'string', format: 'date-time' },
          etapa: {
            type: 'object',
            required: ['codigo_nasp'],
            properties: {
              codigo_nasp: { type: 'string', enum: ['digitado', 'em_validacao', 'pendente', 'em_averbacao', 'averbado', 'aguardando_assinatura', 'aguardando_pagamento', 'credito_liberado', 'recusado', 'cancelado'] },
              proposta_corban: { type: 'string', description: 'Ignorado: o Corban faz a correspondência.' },
              pago_ao_cliente_em: { type: 'string', format: 'date', description: 'Obrigatório em credito_liberado. Não pode ser futura.' },
              observacao: { type: 'string', maxLength: 500, description: 'Vai como motivo da pendência.' },
            },
          },
          contrato: {
            type: 'object',
            required: ['banco', 'tipo_operacao', 'tabela', 'prazo_meses', 'valor_liberado'],
            properties: {
              banco: { type: 'string', description: 'Nome do banco como cadastrado no Corban (ex.: "NASP").' },
              ade: { type: 'string', maxLength: 40, description: 'Nula até a averbação. Pode mudar depois.' },
              numero_interno: { type: 'string', description: 'Só informativo.' },
              tipo_operacao: { type: 'string', enum: ['novo', 'refinanciamento', 'compra_divida', 'portabilidade'] },
              convenio: { type: 'string', description: 'Só informativo.' },
              tabela: { type: 'string', description: 'Nome da sua tabela. O Corban acha a tabela cujo nome termina em " - <tabela>" no banco, ou a correspondência cadastrada.' },
              prazo_meses: { type: 'integer', minimum: 1, maximum: 420 },
              valor_liberado: { $ref: '#/components/schemas/Money', description: 'Valor bruto do contrato. É o "valor liberado" do Corban.' },
              valor_liquido_cliente: { $ref: '#/components/schemas/Money', description: 'Conferido, não gravado.' },
              valor_parcela: { $ref: '#/components/schemas/Money' },
              banco_origem: { type: 'string' },
              contrato_origem: { type: 'string' },
              saldo_devedor_origem: { $ref: '#/components/schemas/Money' },
            },
          },
          vendedor: {
            type: 'object',
            properties: {
              parceiro: { type: 'string', description: 'Só informativo.' },
              agente: { type: 'string', description: 'Vendedor no Corban, pelo nome exato (sem diferença de maiúsculas e acentos). Não achado: contrato sem vendedor e aviso.' },
            },
          },
          cliente: {
            type: 'object',
            required: ['cpf', 'nome'],
            description: 'Ficha do cliente. Preenche só o que estiver vazio no Corban; campo ruim vira aviso, nunca recusa o contrato.',
            properties: {
              cpf: { type: 'string' }, nome: { type: 'string' }, telefone: { type: 'string' }, celular: { type: 'string' }, whatsapp: { type: 'string' },
              email: { type: 'string' }, data_nascimento: { type: 'string', format: 'date' }, sexo: { type: 'string' }, estado_civil: { type: 'string' },
              naturalidade: { type: 'string', description: '"Cidade/UF"' }, nome_mae: { type: 'string' }, nome_pai: { type: 'string' },
              rg: { type: 'string' }, rg_orgao_emissor: { type: 'string' }, rg_uf: { type: 'string' }, rg_data_expedicao: { type: 'string', format: 'date' },
              endereco: { type: 'object', properties: { cep: { type: 'string' }, logradouro: { type: 'string' }, numero: { type: 'string' }, complemento: { type: 'string' }, bairro: { type: 'string' }, cidade: { type: 'string' }, uf: { type: 'string' } } },
              matricula: { type: 'object', properties: { numero: { type: 'string' }, secretaria: { type: 'string' }, categoria_servidor: { type: 'string' } } },
              conta_bancaria: { type: 'object', properties: { banco_codigo: { type: 'string' }, banco_nome: { type: 'string' }, agencia: { type: 'string' }, conta: { type: 'string' }, conta_digito: { type: 'string' }, tipo: { type: 'string' } } },
            },
          },
        },
      },
      ContractResult: {
        type: 'object',
        properties: {
          id: { type: 'string', format: 'uuid' },
          created: { type: 'boolean' },
          duplicate: { type: 'boolean', description: 'O contrato já existia.' },
          stale: { type: 'boolean', description: 'Chamada mais antiga que a última aplicada: nada mudou.' },
          stage: { type: 'string', enum: ['digitization_queue', 'digitizing', 'submitted', 'pending_external', 'approved', 'paid', 'rejected', 'cancelled'] },
          warnings: { type: 'array', items: { type: 'string' }, description: 'Ex.: seller_not_found, stage_locked, invalid_email, client_field_not_saved:endereco.' },
        },
      },
    },
  },
  security: [{ bearer: [] }],
  paths: {
    '/leads': {
      post: {
        summary: 'Criar lead',
        description: 'Cria um lead na empresa da chave. Se já existir lead aberto com o mesmo telefone ou a mesma external_ref, devolve o existente.',
        requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/LeadInput' } } } },
        responses: {
          '201': { description: 'Lead criado', content: { 'application/json': { schema: { $ref: '#/components/schemas/LeadResult' } } } },
          '200': { description: 'Lead já existia (duplicate: true)', content: { 'application/json': { schema: { $ref: '#/components/schemas/LeadResult' } } } },
          '401': { description: 'Chave inválida ou revogada' },
          '403': { description: 'Chave sem escopo ou módulo desligado' },
          '422': { description: 'Dados inválidos', content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } },
          '429': { description: 'Limite de chamadas por minuto atingido' },
        },
      },
    },
    '/contracts': {
      post: {
        summary: 'Criar ou atualizar contrato',
        description: 'Envie o estado completo do contrato a cada mudança de etapa. Chave com uso "Contratos". A chave age como o administrador que a criou. Contrato pago, recusado ou cancelado não muda mais de etapa pela API.',
        requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/ContractInput' } } } },
        responses: {
          '201': { description: 'Contrato criado', content: { 'application/json': { schema: { $ref: '#/components/schemas/ContractResult' } } } },
          '200': { description: 'Contrato atualizado, ou chamada repetida/antiga ignorada', content: { 'application/json': { schema: { $ref: '#/components/schemas/ContractResult' } } } },
          '400': { description: 'JSON inválido' },
          '401': { description: 'Chave inválida ou revogada' },
          '403': { description: 'Chave sem escopo, módulo desligado ou dono da chave não é mais administrador' },
          '422': {
            description: 'Dado recusado: stage_unknown, paid_on_required, invalid_paid_on, bank_not_found, contract_type_unknown, table_not_found, table_ambiguous, term_out_of_table, invalid_term, invalid_amount, invalid_ade, invalid_cpf, full_name_required, invalid_external_id, invalid_sequence, invalid_sent_at, contract_linked_elsewhere',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '429': { description: 'Limite de chamadas por minuto atingido' },
          '500': { description: 'Erro do Corban: tente de novo' },
          '503': { description: 'Corban indisponível: tente de novo' },
        },
      },
    },
  },
}

export function GET() {
  return NextResponse.json(spec)
}
