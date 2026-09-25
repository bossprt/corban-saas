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
  },
}

export function GET() {
  return NextResponse.json(spec)
}
