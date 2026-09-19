# Pilot gap analysis (2026-09-23)

Method: routes, RPCs, harness results and live advisors were compared with what a promotora needs on day one. Nothing below is guessed from marketing; each line is something the code or the database shows.

## What works end to end today (proved by rollback-only harnesses on the live schema)
Lead → cliente → simulação → proposta → documentos → esteira (transições governadas) → integração com run/worker/fencing/retry/cancel/reexecução → evidência → import/matching → verdade financeira somente por evidência governada → conciliação. Isolamento de tenant, RBAC e o firewall financeiro (provider dizendo "paid" não gera receita) foram atacados por todos os papéis.

## P0 — impede o piloto
| # | Gap | Por que | Estado |
|---|---|---|---|
| P0-1 | Aplicar `20260923_worker_dispatch_hardening_v1` e `20260924_confirm_paid_replay_v1` | o worker novo chama a assinatura nova de dispatch; replay de PAID falha hoje | HUMAN GATE (revisão ChatGPT) |
| P0-2 | Convite / gestão de usuários da organização | só existe criação de organização por administrador de plataforma (`/api/admin/organizations`); não há tela para o dono da promotora adicionar agentes/supervisores nem revogar acesso | precisa decisão (provedor de e-mail, política de senha) → HUMAN GATE |
| P0-3 | Alguém acionar o worker | a rota existe, está desabilitada e não é agendada | HUMAN GATE (segredo + agendador) |
| P0-4 | Decisão: agent vê comissão? | `simulations.expected_commission_amount` e `proposals_v2.expected_commission_amount` são legíveis por agent; a regra de negócio não foi decidida | decisão comercial |

## P1 — logo depois do piloto
- Escrita de `simulations` ainda é INSERT/UPDATE direto por qualquer membro (o app faz `insert`); mesmo padrão de governança já aplicado a proposals (RPC + token).
- Primeiro provider real (2Tech aguarda arquivo real; homologação em `docs/integrations/2TECH-BUSCACONTRATO-HOMOLOGATION.md`).
- Tela de histórico de tentativas por execução (os diagnósticos existem no banco após a migration 0923).
- Notificação ao operador quando uma execução vira "aguardando ação humana".
- Leaked Password Protection (configuração do Auth).

## P2 — melhorias
- Métricas persistidas (hoje derivadas do stream de eventos), painel de saúde do worker.
- Cancelamento de execução em andamento (hoje explicitamente recusado; exigiria cooperação do provider).
- Prioridade de execução (o domínio ainda não a define; nenhuma foi inventada).
- Limpeza de índices não usados: só depois de haver tráfego real.

## Implementado nesta onda por ser P0 independente e reversível
Mensagens de erro classificadas na esteira e nas integrações (o operador distingue transição inválida, falta de permissão, estado que mudou e erro inesperado), estados de carregando/erro/indisponível, linhagem visual de reexecução.
