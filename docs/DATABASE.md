markdown
# DATABASE — CORBAN ENTERPRISE

**Versão:** 1.0
**Data:** 11/09/2026
**Compatível com Master:** v1.1
**Camada:** intermediária

---

# 0. PROPÓSITO

Este arquivo define **como** os dados são modelados, versionados e isolados.

- Não substitui o master (conceito).
- Não substitui o current-state (realidade).
- É a referência técnica para qualquer migration, schema ou query.

---

# 1. PRINCÍPIOS

1. Toda tabela de negócio tem `organization_id NOT NULL`.
2. RLS ativado em todas as tabelas de negócio.
3. Nenhuma query sem filtro de tenant.
4. Migrations versionadas no repositório.
5. Tabelas de versão são imutáveis após publicadas.
6. Registros financeiros críticos são imutáveis.
7. Soft delete é o padrão para entidades de negócio.
8. Timestamps sempre em UTC.

---

# 2. CONVENÇÕES

| Item | Convenção |
|---|---|
| Nome de tabela | `snake_case` plural (`clients`, `proposals`) |
| Nome de coluna | `snake_case` (`organization_id`, `created_at`) |
| Chave primária | `id` (UUID v7 preferencialmente) |
| Timestamps | `created_at`, `updated_at` (UTC) |
| Soft delete | `deleted_at` (nullable) |
| Tenant | `organization_id` em toda tabela de negócio |
| Migration | `YYYYMMDDHHMMSS_descricao.sql` |
| Índice | `idx_<tabela>_<colunas>` |
| Constraint | `ck_<tabela>_<regra>` |
| FK | `fk_<tabela>_<tabela_referenciada>` |

---

# 3. IDENTIFICADORES

**UUID v7** (time-ordered) para todas as chaves primárias.

Motivos:
- Ordenável por tempo (melhor performance em índices)
- Globalmente único
- Sem colisão entre tenants
- Melhor que UUID v4 para inserções sequenciais

Se Drizzle ou Supabase não suportar UUID v7 nativamente, usar UUID v4 como fallback.

---

# 4. ISOLAMENTO MULTI-TENANT

## 4.1 Regra geral

Toda tabela de negócio possui:
```sql
organization_id UUID NOT NULL REFERENCES organizations(id)
4.2 RLS padrão
sql
ALTER TABLE <tabela> ENABLE ROW LEVEL SECURITY;

CREATE POLICY <tabela>_tenant_isolation ON <tabela>
  USING (organization_id = (auth.jwt() ->> 'organization_id')::uuid);
4.3 Regras de exceção
Tabelas sem organization_id (por natureza global):

organizations

permissions (catálogo global)

feature_flags_catalog (catálogo global)

migrations (controle do sistema)

Todas as demais precisam de organization_id.

5. GRUPOS DE TABELAS
5.1 Plataforma
text
organizations           → tenant raiz
users                   → identidade global
memberships             → user × organization × role
roles                   → papéis por organização
permissions             → catálogo global
role_permissions        → N:N
teams                   → equipes
team_members            → N:N
feature_flags           → flags por organização
5.2 Comercial
text
leads                   → leads não qualificados
clients                 → clientes (CPF validado)
contacts                → contatos de um cliente
brokers                 → corretores (entidade comercial)
broker_rules            → regras específicas de corretor
5.3 Produtos
text
banks                   → bancos (global ou por org)
agreements              → convênios banco × corban
products                → produtos bancários
modalities              → modalidades do produto
product_tables          → identidade lógica da tabela
product_table_versions  → versão imutável
5.4 Operação
text
pipelines               → esteira por organização
pipeline_stages         → etapas de cada esteira
proposals               → propostas
proposal_stage_history  → histórico de mudança de etapa
timeline_events         → timeline universal
slas                    → SLA por etapa
tasks                   → tarefas operacionais
5.5 Documentos e Contratos
text
documents               → documentos (entidade própria)
contracts               → contratos
contract_templates      → templates versionados
signatures              → evidências de assinatura
5.6 Financeiro
text
commission_rules         → regras de comissão (identidade)
commission_rule_versions → versões imutáveis
commissions              → comissões calculadas/pagas
commission_adjustments   → ajustes (imutáveis)
commissions_received     → comissões recebidas do banco
reconciliation_entries   → conciliação
5.7 Infra / Suporte
text
events                   → event store leve
audit_logs               → auditoria (imutável)
notifications            → notificações
webhooks_out             → webhooks de saída
imports                  → importações
import_logs              → logs de importação
idempotency_keys         → controle de idempotência
6. MODELAGEM CRÍTICA
6.1 clients — unicidade de CPF
CPF único por organização, com índice parcial ignorando soft delete:

sql
CREATE UNIQUE INDEX clients_org_cpf_active_uniq
  ON clients (organization_id, cpf)
  WHERE deleted_at IS NULL;
Motivos:

Não há unicidade global entre tenants (LGPD + realidade de mercado).

Soft delete não bloqueia recadastro.

Validação dupla: no backend (Zod) + índice no banco.

6.2 product_tables + product_table_versions
Separação obrigatória:

text
product_tables
- id
- organization_id
- bank_id
- agreement_id
- product_id
- modality_id
- code
- status (active | archived)

product_table_versions
- id
- product_table_id (FK)
- version (1, 2, 3...)
- effective_from
- effective_until (nullable)
- rate
- coefficient
- commission_rule_id
- created_by
- created_at
- notes
Regras:

Versão publicada é imutável.

Para alterar regra, criar nova versão com effective_from posterior.

Proposta armazena product_table_version_id, não só o produto.

6.3 commissions — máquina de estados
text
Calculated → Validated → Approved → Released → Paid
     ↓            ↓           ↓          ↓        ↓
  Disputed    Disputed    Disputed   Reversed  Reversed
     ↓
  Adjusted → (novo Calculated)
Regras:

Comissão paga é imutável.

Ajuste gera novo registro em commission_adjustments.

Toda mudança de estado gera evento + auditoria.

6.4 audit_logs — imutável
Campos:

id

organization_id

user_id

action (create | update | delete | login | export | ...)

entity

entity_id

before (jsonb, nullable)

after (jsonb, nullable)

reason (nullable)

ip

user_agent

created_at

Regras:

Sem UPDATE nem DELETE.

Sem soft delete — é append-only.

Índices: (organization_id, created_at), (entity, entity_id).

6.5 idempotency_keys
Campos:

key (PK)

organization_id

endpoint

request_hash

response (jsonb)

created_at

expires_at

Uso:

Operações financeiras

Webhooks de entrada

Jobs de fila

Regra: TTL padrão de 24h.

7. SOFT DELETE × HARD DELETE
Entidade	Estratégia
clients, leads, documents, contacts	Soft delete (deleted_at)
proposals, contracts	Status cancelled (nunca delete)
commissions (pagas)	Imutáveis
audit_logs	Imutáveis, append-only
product_table_versions	Imutáveis
commission_rule_versions	Imutáveis
contract_templates	Imutáveis após publicados
organizations, users	Soft delete + anonimização LGPD
8. ÍNDICES OBRIGATÓRIOS
Toda tabela de negócio:

organization_id

created_at DESC (para ordenação)

Quando fizer sentido:

(organization_id, status)

(organization_id, owner_id)

(organization_id, deleted_at) (parcial para soft delete)

Tabelas transacionais:

proposals (organization_id, status)

proposals (organization_id, product_table_version_id)

commissions (organization_id, status, created_at)

leads (organization_id, owner_id, status)

audit_logs (entity, entity_id)

9. ROW LEVEL SECURITY (RLS)
9.1 Ativação obrigatória
Toda tabela de negócio tem RLS habilitado desde a criação.

9.2 Policy padrão
sql
CREATE POLICY <tabela>_tenant_isolation ON <tabela>
  USING (organization_id = (auth.jwt() ->> 'organization_id')::uuid);
9.3 Policies adicionais
Quando houver escopo mais fino (ex.: vendedor só vê própria carteira), adicionar policies complementares.

9.4 Testes de RLS
Teste por tenant obrigatório

Teste de acesso negado entre tenants

Teste de escalação de privilégios

10. MIGRATIONS
Ferramenta: Drizzle Kit

Local: /migrations

Nome: YYYYMMDDHHMMSS_descricao.sql

Toda migration tem teste de rollback

Nunca alterar migration já aplicada em produção

Migrations aplicadas via drizzle-kit push (dev) ou drizzle-kit migrate (produção)

11. VERSIONAMENTO
Tabelas versionadas (nunca sobrescrever):

product_table_versions

commission_rule_versions

contract_templates

Regra geral:

Adicionar nova versão com effective_from posterior

Nunca editar versão publicada

Deixar vigência explícita (effective_until)

12. BACKUP E DR
Backup automático do Postgres (Supabase)

PITR quando disponível

Retenção mínima: 30 dias

RPO: 1 hora

RTO: 4 horas

Teste de restore trimestral

Procedimento documentado em /docs/DR.md (a criar)

13. LGPD
Minimização de dados

Anonimização quando possível

Exclusão lógica (não física) para retenção

Exportação controlada por permissão

Registro de acesso a dados pessoais em audit_logs

14. PENDÊNCIAS
#	Ponto	Status
P1	Confirmar suporte a UUID v7 no Supabase	A verificar
P2	Estratégia de particionamento (para grandes volumes)	Avaliar na fase 8
P3	Retenção de audit_logs (definitiva ou periódica?)	Definir antes de produção
P4	Estratégia de arquivamento de dados antigos	Avaliar na fase 10
FIM