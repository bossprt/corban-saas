# CORBAN ENTERPRISE

SaaS Enterprise para Correspondentes Bancários (Corban).

**Objetivo:** criar um **Sistema Operacional para Corbans** — não apenas um CRM.

---

## Visão em uma frase

Controlar vendas, rede comercial, operação, esteira de propostas/contratos, documentos, comissões, conciliação, gestão, automações e IA em uma única plataforma multi-tenant.

---

## Documentação obrigatória (leia nesta ordem)

Se você é uma IA, um desenvolvedor novo ou está retomando o projeto após uma pausa, **leia nesta ordem**:

1. [`CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md`](./CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md) — fonte de verdade **conceitual** (como DEVE ser)
2. [`CORBAN-CURRENT-STATE.md`](./CORBAN-CURRENT-STATE.md) — estado **real** do código (o que EXISTE)
3. [`/.ai/RULES.md`](./.ai/RULES.md) — regras operacionais
4. [`/.ai/MASTER-CONTEXT.md`](./.ai/MASTER-CONTEXT.md) — contexto mínimo
5. [`/.ai/CURRENT-TASK.md`](./.ai/CURRENT-TASK.md) — foco da sessão atual
6. [`/.ai/DECISIONS.md`](./.ai/DECISIONS.md) — por que cada decisão foi tomada
7. [`/.ai/CHANGELOG.md`](./.ai/CHANGELOG.md) — o que mudou
8. [`/docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — arquitetura detalhada
9. [`/docs/DATABASE.md`](./docs/DATABASE.md) — modelo de dados
10. [`/docs/RBAC.md`](./docs/RBAC.md) — papéis e permissões

---

## Regra fundamental

**MASTER ≠ CURRENT-STATE**

- O **master** descreve o que **deve** existir.
- O **current-state** descreve o que **existe** agora.
- Nunca tratar como implementado algo que só está no master.

---

## Stack

- **Framework:** Next.js 16.3.4 (App Router) — atenção: breaking changes
- **Linguagem:** TypeScript
- **Estilo:** Tailwind CSS 4
- **Banco & Auth:** Supabase (PostgreSQL + RLS)
- **ORM:** Drizzle ORM (a instalar)
- **Validação:** Zod (a instalar)
- **Filas:** BullMQ + Redis (fase futura)
- **Testes:** Vitest + Playwright (a instalar)
- **Ícones:** Lucide React

---

## Status atual

Ver [`CORBAN-CURRENT-STATE.md`](./CORBAN-CURRENT-STATE.md).

**Fase atual:** FASE 1 (Fundação técnica) — em andamento.

**O que já existe:**
- Repositório Git (privado)
- Next.js + TypeScript + Tailwind
- Supabase conectado
- Documentação de governança para IAs

**O que NÃO existe ainda:**
- Migrations versionadas
- RLS aplicada
- Multi-tenant funcional
- CRM, esteira, comissão, IA, WhatsApp

---

## Estrutura de pastas


/
├── src/
│ ├── app/ # Next.js App Router
│ ├── lib/ # bibliotecas internas
│ ├── utils/ # utilitários
│ └── server/ # Domain Services (a criar)
├── public/ # assets estáticos
├── migrations/ # migrations SQL (a criar)
├── tests/ # testes (a criar)
├── docs/ # documentação técnica
├── .ai/ # arquivos operacionais de IA
├── CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md
├── CORBAN-CURRENT-STATE.md
└── README.md

text

---


## Setup local

### Pré-requisitos

- Node.js 20+
- npm / pnpm / yarn / bun
- Conta no Supabase

### Passos

```bash
# 1. Clonar
git clone https://github.com/bossprt/corban-saas.git
cd corban-saas

# 2. Instalar dependências
npm install

# 3. Copiar variáveis de ambiente
cp .env.example .env.local
# preencher com credenciais do Supabase

# 4. Rodar em desenvolvimento
npm run dev


Acesse http://localhost:3000.

Scripts disponíveis


npm run dev        # desenvolvimento
npm run build      # build de produção
npm run start      # start em produção
npm run lint       # lint

(Testes, migrations e outros scripts serão adicionados conforme a FASE 1 avança.)

Como contribuir (humano ou IA)
Leia /.ai/RULES.md — regras operacionais obrigatórias

Verifique /.ai/CURRENT-TASK.md — foco atual

Toda mudança deve responder à Regra de Ouro (master, seção 55)

Ao final: atualize CORBAN-CURRENT-STATE.md, /.ai/CHANGELOG.md e /.ai/CURRENT-TASK.md

Faça commit com mensagem descritiva

Continuidade entre IAs e sessões

Este projeto foi desenhado para ser retomado por qualquer IA.

Arquivo	        Papel
Master	        Conceito estável
Current State	Realidade volátil
Rules	        Como operar
Decisions	Por que decidimos assim
Changelog	O que mudou
Current Task	Foco atual

Regra: Nenhuma IA deve reinventar arquitetura já decidida.

Modelo de trabalho:

IA arquiteta (chat) → decide, documenta, gera prompt

IA executora (VS Code) → executa, edita, commita

Usuário → ponte entre os dois

Licença
Proprietário. Todos os direitos reservados.

Contato
Repositório: https://github.com/bossprt/corban-saas

text

---

## Depois de salvar

```powershell
cd "C:\VS CODE - JOSICLEUTOn\corban-saas"

git add README.md
git commit -m "docs: substituir README boilerplate por README real do projeto"
git push


