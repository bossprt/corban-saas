markdown
# ARCHITECTURE — CORBAN ENTERPRISE

**Versão:** 1.0
**Data:** 11/09/2026
**Compatível com Master:** v1.1
**Camada:** intermediária (entre master e implementação)

---

# 0. PROPÓSITO DESTE ARQUIVO

Este arquivo traduz o **conceito** (master) em **decisões técnicas concretas**.

- O master diz **o que** o sistema deve ter.
- Este arquivo diz **como** tecnicamente isso se organiza.
- O current-state diz **o que** já existe no código.

Se houver conflito entre este arquivo e o master, o master vence.
Se houver conflito entre este arquivo e o código, o código atual é a realidade — **atualize este arquivo** ou o código.

---

# 1. VISÃO ARQUITETURAL

O sistema segue uma arquitetura **em camadas + orientada a eventos**, com isolamento multi-tenant em nível de banco (RLS) e domínio (Domain Services).

**Princípios:**

1. Frontend nunca fala direto com o banco de dados.
2. Regras de negócio vivem em Domain Services.
3. Operações pesadas vão para filas (BullMQ).
4. Tudo que é crítico gera evento + auditoria.
5. IA atua como **agente supervisionado**, nunca dona da verdade.
6. Toda camada é testável isoladamente.

---

# 2. DIAGRAMA DE CONTEXTO (C4 — Nível 1)

```mermaid
graph LR
  U[Usuário] --> FE[Next.js Frontend]
  FE --> API[API / BFF]
  API --> DB[(PostgreSQL + RLS)]
  API --> Q[Queue / Redis]
  Q --> W[Workers]
  W --> EXT[Integrações]
  API --> AI[Agentes de IA]
  AI --> LLM[LLMProvider]
  API --> S3[Storage privado]
3. CAMADAS
3.1 Frontend
Responsabilidade: apresentação, interação, feedback visual.

Tecnologia: Next.js 16.3.4 (App Router), React 19, Tailwind CSS 4.

Regras:

Server Components para leitura

Server Actions para mutações internas

Nunca contém regra de negócio crítica

Nunca fala direto com banco

Nunca confia em autorização própria — backend é soberano

Estrutura:

text
src/app/
  (auth)/          → rotas públicas (login, cadastro)
  (dashboard)/     → rotas autenticadas
  api/v1/          → route handlers
3.2 API / BFF
Responsabilidade: ponto único de entrada, orquestração, validação.

Tecnologia: Next.js Route Handlers (src/app/api/v1/*).

Regras:

Autenticação + autorização obrigatórias

Validação com Zod

Chama Domain Services

Nunca contém regra de negócio

Ponto único para integrações externas

3.3 Application Layer
Responsabilidade: orquestração de casos de uso.

Regras:

Não contém regra de negócio

Conhece transações, idempotência, retries

Chama um ou mais Domain Services

Retorna DTOs, nunca entidades

3.4 Domain Services
Responsabilidade: regras de negócio.

Serviços previstos:

CrmService

EsteiraService

SimulationService

CommissionService

DocumentService

ComercialService

ContractService

ReconciliationService

Regras:

Não conhecem HTTP

Não conhecem Next.js

Não conhecem banco diretamente (usam repositories)

São testáveis isoladamente

Recebem e retornam tipos de domínio (não DTOs de API)

3.5 Infraestrutura
Componentes:

PostgreSQL (Supabase) com RLS

Drizzle ORM (queries e migrations)

Storage privado (Supabase Storage)

Redis + BullMQ (filas)

Workers dedicados (processos separados)

3.6 Integrações
Camada IntegrationLayer:

Um adapter por provedor

Contrato comum (send, receive, status)

Retry com backoff exponencial

DLQ para falhas persistentes

Assinatura HMAC

Idempotência obrigatória

Adapters previstos:

WhatsAppAdapter

BankAdapter (por banco)

SignatureAdapter (assinatura eletrônica)

EmailAdapter

SmsAdapter

3.7 IA
Componentes:

Interface LLMProvider (abstração)

Agentes especializados

Motor de regras determinísticas (bloqueios críticos)

Auditoria completa

Regras:

IA nunca tem acesso irrestrito

Toda ação registrada (prompt, contexto, output, decisão)

Ações reversíveis sempre que possível

Motor de regras controla bloqueios críticos

Humano supervisiona ações críticas

4. FLUXO DE REQUISIÇÃO TÍPICA
text
Usuário
→ Next.js (Server Component ou Server Action)
→ API/BFF (Route Handler)
→ Autenticação + autorização + Zod
→ Application Layer
→ Domain Service
→ Drizzle → PostgreSQL (RLS aplica isolamento)
→ Evento publicado (fila)
→ Worker processa (notificação, IA, integração)
→ Realtime atualiza frontend
5. FLUXO ASSÍNCRONO (EXEMPLO: WHATSAPP)
5.1 Entrada (webhook recebido)
text
WhatsApp → Webhook → API
  → valida HMAC
  → valida idempotency_key
  → publica job
→ Worker
  → processa
  → grava no banco
  → dispara evento
→ Realtime
→ Frontend
5.2 Saída (mensagem enviada)
text
Domain Service
  → publica job
→ Worker
  → Adapter WhatsApp
  → API externa
  → registra resultado
  → atualiza status
6. PADRÕES ADOTADOS
Padrão	Onde é usado
Repository	Acesso a dados via Drizzle
Domain Service	Regras de negócio
Event-driven	Esteira, notificações, IA
Adapter	Integrações externas
Idempotency Key	Operações financeiras, webhooks
Optimistic Lock	Movimentação de proposta
Soft Delete	Clientes, leads, documentos
Immutable Records	Comissões pagas, audit_logs
Feature Flags	Ativação por tenant
LLMProvider	Abstração de IA
7. ESTRUTURA DE PASTAS (ALVO)
text
/
├── src/
│   ├── app/                    # Next.js App Router
│   │   ├── (auth)/             # rotas públicas
│   │   ├── (dashboard)/        # rotas autenticadas
│   │   └── api/v1/             # route handlers
│   ├── components/             # componentes React reutilizáveis
│   ├── lib/                    # bibliotecas internas
│   │   ├── db/                 # Drizzle client + schema
│   │   ├── auth/               # autenticação
│   │   ├── rbac/               # autorização
│   │   ├── events/             # barramento de eventos
│   │   ├── queue/              # BullMQ
│   │   ├── ai/                 # LLMProvider + agentes
│   │   ├── integrations/       # adapters externos
│   │   └── validation/         # schemas Zod
│   ├── server/
│   │   ├── services/           # Domain Services
│   │   └── actions/            # Server Actions
│   └── utils/                  # utilitários puros
├── workers/                    # processos BullMQ
├── migrations/                 # SQL migrations (Drizzle)
├── tests/
│   ├── unit/
│   ├── integration/
│   └── e2e/
├── docs/                       # documentação técnica
├── .ai/                        # arquivos operacionais de IA
└── (arquivos de configuração na raiz)
8. REGRAS DE OURO ARQUITETURAIS
Nenhuma regra de negócio em componente React.

Nenhuma query sem filtro de organization_id.

Nenhuma operação financeira sem idempotência.

Nenhuma ação da IA sem auditoria.

Nenhuma migração sem teste de rollback.

Nenhuma feature sem responder à "Regra de Ouro" (master, seção 55).

Nenhum any sem justificativa.

Nenhuma dependência direta de fornecedor de IA específico.

Nenhum DELETE em audit_logs nem em comissões pagas.

Nenhuma alteração em migration já aplicada em produção.

9. ESCALABILIDADE
RLS garante isolamento mesmo com 10k tenants.

Índices em organization_id em todas as tabelas de negócio.

Filas absorvem picos.

Workers escalam horizontalmente.

Storage privado por tenant (prefixo de path).

Cache de leitura (Redis) para consultas frequentes.

Paginação obrigatória em listagens.

10. OBSERVABILIDADE
Logs estruturados (pino)

Eventos publicados (event store leve)

Métricas por fila

Healthcheck por serviço

Tracing de requisições críticas (a avaliar)

Painel consolidado (fase futura)

11. SEGURANÇA (VISÃO ARQUITETURAL)
RLS em todas as tabelas de negócio

Backend soberano em autorização

Validação com Zod em toda entrada

Rate limiting por tenant

HMAC em webhooks

Storage privado com signed URLs

Segredos nunca no repositório

Auditoria de toda ação sensível

12. DECISÕES RELACIONADAS
Ver /.ai/DECISIONS.md:

ADR-0001: RLS

ADR-0002: Drizzle

ADR-0003: BullMQ

ADR-0004: ProductTable/Version

ADR-0007: LLMProvider

ADR-0009: src/app/

ADR-0010: múltiplas IAs

13. PENDÊNCIAS ARQUITETURAIS
#	Ponto	Status
P1	Monorepo ou app único?	App único por ora
P2	Autenticação: Supabase Auth ou Auth.js?	Supabase Auth (recomendado)
P3	Hospedagem final	Vercel + Supabase (recomendado)
P4	Tracing distribuído	A avaliar
P5	Cache de leitura	A avaliar quando houver gargalo

FIM