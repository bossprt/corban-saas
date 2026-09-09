# Projeto: SaaS Corban Enterprise

## Visão Geral
Sistema SaaS multi-tenant desenvolvido para Correspondentes Bancários (Corban), focado em CRM de leads, esteira automatizada de contratos e conciliação inteligente de comissões.

## Stack Tecnológica
- **Framework:** Next.js (App Router, TypeScript)
- **Estilização:** Tailwind CSS
- **Banco de Dados & Auth:** Supabase (PostgreSQL + Row Level Security - RLS)
- **Ícones & UI:** Lucide-React

## Módulos do Sistema
1. **Multi-Tenant:** Isolamento rigoroso de dados por organização e níveis de acesso (Admin, Gerente, Supervisor, Digitador).
2. **CRM & Vendas:** Gestão de clientes, CPFs únicos por tenant e simuladores de margem.
3. **Esteira de Contratos:** Pipeline de acompanhamento de status de propostas de crédito.
4. **Conciliação de Comissões:** Regras por banco, percentuais, impostos e trava de segurança de verificação humana.
5. **Migração & Importação:** Suporte futuro a importação de planilhas de backup de sistemas legados.