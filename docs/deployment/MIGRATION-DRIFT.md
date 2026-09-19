# Migration drift - repositório x Supabase LIVE (2026-09-25)

Método: lista de migrations aplicadas (`list_migrations`, 76 registros) comparada, pelo NOME, com os 76 arquivos de `supabase/migrations/`. As versões (timestamps) diferem porque o Supabase registra a data de aplicação e o repositório usa a data de preparo; o que vale para comparar é o nome.

| Situação | Migration | Observação |
|---|---|---|
| Aplicada e presente no repositório | 75 migrations por nome (de `organization_memberships_v2` a `revoked_actor_dispatch_v1`) | sem divergência |
| Presente no repositório, NÃO aplicada | `20260929_catalog_publish_v1` | preparada, harness rollback-only 40/40; aguarda revisão do ChatGPT. Publica versão de tabela e checklist sem SQL |
| Aplicada, sem arquivo no repositório | `harden_legacy_rls_foundation` (20260917192754) | baseline anterior à criação do repositório de migrations; nenhuma ação |
| Duplicadas / renomeadas | nenhuma encontrada | |

O script `npm run preflight` só conta os arquivos; nunca aplica nem consulta o banco. Reconferir depois de cada aplicação pelo ChatGPT.
