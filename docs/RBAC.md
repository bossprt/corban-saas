markdown
# RBAC — CORBAN ENTERPRISE

**Versão:** 1.0
**Data:** 11/09/2026
**Compatível com Master:** v1.1
**Camada:** intermediária

---

# 0. PROPÓSITO

Este arquivo define **como** funciona autenticação, autorização, papéis e permissões.

- Autenticação: quem é o usuário.
- Autorização: o que ele pode fazer.
- Isolamento: o que ele pode ver.

---

# 1. PRINCÍPIOS

1. Cargo **não** é a única camada de autorização.
2. Permissões são **granulares** e atribuídas a **papéis**.
3. Papéis são atribuídos a **memberships** (user × organization).
4. Toda permissão é validada no **backend**.
5. RLS reforça isolamento no banco.
6. Frontend pode esconder botões, mas backend é soberano.
7. Toda negativa de autorização é registrada em auditoria.
8. IA possui membership própria, com permissões restritas.

---

# 2. MODELO
User
└── Membership (por organização)
├── Role
│ └── RolePermission
│ └── Permission
└── TeamMember

text

- Um **User** pode pertencer a várias organizações.
- Em cada organização, ele tem **um Membership**.
- Cada Membership tem **um Role**.
- Cada Role tem **N Permissions**.

---

# 3. ENTIDADES

## 3.1 `users`

Identidade global. Não pertence a tenant.

Campos:
- `id` (UUID)
- `email` (único global)
- `password_hash` (ou delegado ao Supabase Auth)
- `name`
- `phone`
- `created_at`
- `updated_at`
- `deleted_at`

## 3.2 `organizations`

Tenant raiz.

Campos:
- `id`
- `name`
- `slug` (único global)
- `plan` (free | starter | professional | enterprise)
- `status` (active | suspended | cancelled)
- `created_at`
- `updated_at`

## 3.3 `memberships`

Liga `users` a `organizations` com `role_id`.

Campos:
- `id`
- `organization_id`
- `user_id`
- `role_id`
- `status` (active | invited | suspended)
- `created_at`
- `updated_at`

**Constraint:** `UNIQUE (organization_id, user_id)` — um user só tem um membership por organização.

## 3.4 `roles`

Papéis por organização.

Campos:
- `id`
- `organization_id`
- `name`
- `description`
- `is_system` (boolean — papéis padrão não editáveis)
- `created_at`
- `updated_at`

## 3.5 `permissions`

Catálogo global (não por tenant).

Campos:
- `code` (PK, ex.: `clientes.criar`)
- `description`
- `module`

## 3.6 `role_permissions`

N:N entre `roles` e `permissions`.

Campos:
- `role_id`
- `permission_id`

**Constraint:** `UNIQUE (role_id, permission_id)`.

## 3.7 `teams` e `team_members`

Equipes dentro de uma organização.
teams

id

organization_id

name

parent_team_id (nullable — para hierarquia)

created_at

updated_at

team_members

team_id

user_id

role_in_team (lead | member)

created_at

text

---

# 4. PAPÉIS PADRÃO (SEED)

Criados automaticamente ao criar uma organização:

| Papel | Escopo | `is_system` |
|---|---|---|
| Administrador | Tudo na organização | ✅ |
| Diretor | Visão total, sem configurar plataforma | ✅ |
| Gerente | Equipe(s) sob sua gestão | ✅ |
| Supervisor | Sub-equipe | ✅ |
| Vendedor | Própria carteira | ✅ |
| Digitador | Etapa de digitação | ✅ |
| Mesa Operacional | Etapas operacionais | ✅ |
| Financeiro | Comissões, conciliação | ✅ |
| Auditor | Somente leitura + auditoria | ✅ |
| Corretor | Própria produção | ✅ |
| Parceiro | Própria produção (limitado) | ✅ |

Papéis customizados podem ser criados pela organização (`is_system = false`).

---

# 5. CATÁLOGO DE PERMISSÕES

## 5.1 Módulo: Clientes
clientes.visualizar
clientes.criar
clientes.editar
clientes.excluir
clientes.exportar

text

## 5.2 Módulo: Leads
leads.visualizar
leads.criar
leads.editar
leads.transferir
leads.excluir

text

## 5.3 Módulo: Propostas
propostas.visualizar
propostas.criar
propostas.editar
propostas.aprovar
propostas.cancelar

text

## 5.4 Módulo: Contratos
contratos.visualizar
contratos.criar
contratos.assinar
contratos.cancelar

text

## 5.5 Módulo: Documentos
documentos.visualizar
documentos.enviar
documentos.excluir
documentos.baixar

text

## 5.6 Módulo: Comissões
comissoes.visualizar
comissoes.calcular
comissoes.aprovar
comissoes.pagar
comissoes.ajustar

text

## 5.7 Módulo: Conciliação
conciliacao.visualizar
conciliacao.aprovar
conciliacao.ajustar

text

## 5.8 Módulo: Relatórios
relatorios.visualizar
relatorios.exportar

text

## 5.9 Módulo: Administração
usuarios.gerenciar
permissoes.gerenciar
configuracoes.gerenciar
equipes.gerenciar

text

## 5.10 Módulo: Auditoria
auditoria.visualizar
auditoria.exportar

text

## 5.11 Módulo: Importação
importacao.executar
importacao.visualizar

text

---

# 6. ESCOPO HIERÁRQUICO

Permissões podem ter **escopo**:

| Escopo | Significado |
|---|---|
| `self` | Somente recursos próprios |
| `team` | Recursos da equipe do usuário |
| `org` | Recursos da organização inteira |

Exemplo:
- `leads.visualizar:self` — vê apenas seus leads
- `leads.visualizar:team` — vê leads da equipe
- `leads.visualizar:org` — vê todos os leads da organização

O escopo é parte do Role, não da Permission. Ou seja, o mesmo Role pode ter `leads.visualizar` com escopo diferente.

---

# 7. REGRAS DE AUTORIZAÇÃO

## 7.1 Toda rota de API valida

1. Autenticação (usuário logado)
2. Tenant (usuário pertence à organização)
3. Permissão (usuário tem a permissão necessária)
4. Escopo (o recurso está dentro do escopo)

## 7.2 Toda Server Action valida

Os mesmos 4 pontos acima.

## 7.3 Nenhuma tela assume permissão

Frontend pode esconder botões, mas backend é soberano. Toda ação é revalidada.

## 7.4 RLS como última linha de defesa

Mesmo que backend falhe em autorizar, RLS impede vazamento entre tenants.

---

# 8. FLUXO DE AUTENTICAÇÃO
Usuário acessa /login

Informa e-mail + senha

Supabase Auth valida

JWT é emitido com claims:

sub (user_id)

email

organization_id (ativa)

role_id

Frontend armazena sessão (cookie httpOnly)

Toda requisição envia JWT

Backend valida JWT e extrai claims

RLS aplica isolamento baseado em organization_id

text

## 8.1 Multi-organização

Se o usuário pertence a mais de uma organização, ele escolhe a **ativa** no login. A organização ativa vai no JWT.

Trocar de organização ativa = novo JWT.

---

# 9. FLUXO DE AUTORIZAÇÃO
Requisição chega
→ Middleware verifica autenticação
→ Route Handler verifica permissão + escopo
→ Se OK: chama Domain Service
→ Se NÃO: retorna 403 + registra auditoria

text

---

# 10. PAPÉIS ESPECIAIS

## 10.1 Agente de IA

Possui **membership própria** com papéis limitados.

**Regras:**
- Nunca tem `*` (todas as permissões)
- Nunca tem `usuarios.gerenciar`
- Nunca tem `configuracoes.gerenciar`
- Nunca tem `permissoes.gerenciar`
- Sempre tem permissões apenas de leitura + ações limitadas
- Toda ação da IA é registrada em `audit_logs`

## 10.2 Auditor

**Regras:**
- Somente leitura
- Nunca pode alterar nada
- Pode ver `audit_logs`
- Exportação exige permissão explícita e registra log

## 10.3 Super Admin (plataforma)

Papel acima de qualquer organização. Só existe na plataforma (não em tenant).

**Uso:**
- Suporte técnico
- Auditoria de plataforma
- Nunca acessa dados de negócio sem consentimento e registro

---

# 11. AUDITORIA DE AUTORIZAÇÃO

Toda negativa de autorização deve ser registrada em `audit_logs` com:

- `user_id`
- `organization_id`
- `action` = `authorization_denied`
- `entity` (recurso alvo)
- `entity_id`
- `reason` (permissão faltante, tenant errado, escopo insuficiente)
- `ip`
- `user_agent`

---

# 12. TESTES OBRIGATÓRIOS

## 12.1 Testes por papel

- Cada papel tem teste de acesso permitido
- Cada papel tem teste de acesso negado
- Cada papel tem teste de escopo (`self`, `team`, `org`)

## 12.2 Testes de isolamento

- RLS testado por tenant
- Teste de escalação de privilégios
- Teste de acesso cruzado (user de org A tentando acessar org B)

## 12.3 Testes de auditoria

- Toda negativa gera log
- Todo login gera log
- Toda alteração de permissão gera log

---

# 13. DEPENDÊNCIAS

- **Autenticação:** Supabase Auth (recomendado)
- **JWT:** emitido pelo Supabase, com claims customizadas
- **RLS:** usa `auth.jwt() ->> 'organization_id'`
- **Validação:** Zod para schemas de entrada

---

# 14. PENDÊNCIAS

| # | Ponto | Status |
|---|---|---|
| P1 | Supabase Auth ou Auth.js? | Supabase Auth (recomendado) |
| P2 | Como customizar claims do JWT no Supabase? | A pesquisar |
| P3 | Estratégia de refresh de JWT ao trocar organização ativa | A definir |
| P4 | MFA/2FA | Fase futura |
| P5 | SSO (SAML/OIDC) | Fase Enterprise |

---

# FIM