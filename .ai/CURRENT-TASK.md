# CURRENT TASK — CORBAN OS V2

**Atualização:** 18/09/2026  
**Branch:** `architecture/corban-os-master-v2`

## Foco
Fechar o gate de isolamento Tenant/Auth/Membership V2 e iniciar Customer 360.

## Concluído
- [x] Baseline do Supabase e ADR-0011 documentados.
- [x] Migration `organization_memberships_v2` versionada e aplicada no Supabase.
- [x] Tabela `organization_memberships`, índices, RLS e helper de membership criados.
- [x] Helper novo usa SECURITY INVOKER; não introduziu novo alerta SECURITY DEFINER.
- [x] Advisor identificou RLS initplan; migration `optimize_membership_rls_auth_initplan` aplicada e versionada.
- [x] Advisor pós-correção não reporta mais o initplan do membership.
- [x] Histórico Supabase agora contém: harden_legacy_rls_foundation, organization_memberships_v2, optimize_membership_rls_auth_initplan.
- [x] O alerta de segurança restante pertence ao helper legado `get_user_organization_id()`; será removido/neutralizado somente quando as policies legadas migrarem.
- [x] Nenhuma estrutura legada foi removida.
- [x] Migration aditiva `add_legacy_fk_indexes` aplicada; advisor não reporta mais FKs sem índice.
- [x] Migration de troca das policies legadas para membership preparada no Git, mas NÃO aplicada: gate A/B autenticado ainda pendente.
- [x] Banco está vazio (0 auth.users, 0 organizations, 0 memberships), portanto não foram fabricados usuários/dados no projeto principal para forçar o teste.
- [x] Customer 360 V0 preparado no Git, ainda não aplicado.
- [x] Customer 360 usa FKs compostas tenant-safe para impedir customer/bank account de outro tenant mesmo se a aplicação errar.
- [x] Timeline preparada como append-oriented; tabelas novas não concedem DELETE autenticado.
- [x] ADR-0005 incorporado à migration Customer 360: CPF único por tenant apenas para registros ativos.
- [x] Grants Customer 360 reduzidos por operação; anon sem grants e timeline authenticated somente SELECT/INSERT.
- [x] Contrato SQL pós-DDL criado para verificar RLS, grants, CPF parcial e FKs tenant-safe.
- [x] Catálogo Bank/Provider/Agreement/Product/Modality + OrganizationProductRoute + ProductTable/Version preparado no Git.
- [x] Catálogo global é read-only para authenticated; configuração/tabelas do tenant usam RLS membership.
- [x] FKs compostas bloqueiam rota/tabela/version cross-tenant.
- [x] ProductTableVersion usa NUMERIC e UPDATE autenticado somente enquanto draft; publicação completa ainda exige guarda de domínio/DB.
- [x] Simulation/Proposal V0 preparado no Git, sem aplicação prematura.
- [x] Proposal V2 preserva snapshots de Customer, condições comerciais e atribuição.
- [x] FKs compostas impedem Proposal/Simulation de cruzar Customer ou ProductTableVersion entre tenants.
- [x] Proposal V2 separado de contracts legado; valores usam NUMERIC e não há DELETE authenticated.
- [x] Contrato SQL de segurança/estrutura criado para Simulation/Proposal.
- [x] Document Vault/Checklist V0 preparado no Git, sem aplicação prematura.
- [x] CustomerDocument preserva hash SHA-256 e metadados; Proposal reutiliza evidência por link em vez de duplicar arquivo.
- [x] Checklist versionado por rota; requisitos da Proposal preservam snapshots.
- [x] Exceção documental `waived` exige motivo + aprovador + timestamp.
- [x] FKs compostas e ausência de DELETE authenticated mantidas; contrato SQL de segurança criado.
- [x] Internal Digitization + Operational Pipeline V0 preparado no Git.
- [x] DigitizationJob separado de Proposal com fila, prioridade, responsável, tentativas e referência externa.
- [x] OperationalCase separado de OperationalEvent: posição atual mutável + histórico append-only.
- [x] Stage visual configurável por tenant mantém canonical_state técnico.
- [x] Índice parcial impede duas tarefas ativas de digitação para a mesma Proposal.
- [x] Status externo bruto preservado separadamente; contrato SQL de segurança criado.
- [x] Revisão integrada da cadeia concluída; manifesto de aplicação e matriz de dependências criados.
- [x] Ordem controlada definida: legacy RLS → Customer → Catalog → Simulation/Proposal → Documents → Pipeline.
- [x] Estratégia de recuperação/rollback documentada com preferência por forward-fix após dados reais.
- [x] Contrato pós-DDL das policies legadas criado.
- [x] Migration de policies agora revoga EXECUTE authenticated/anon do helper SECURITY DEFINER legado após a troca.
- [x] Auth/UI real revisado: login legado era apenas visual e browser client não estava alinhado ao SSR.
- [x] Login conectado a Supabase Auth via browser SSR client; middleware/server continuam validando sessão.
- [x] `/app` agora exige sessão + membership ativo; sem membership cai em `/access-pending` fail-closed.
- [x] Bootstrap V0 documentado sem signup público, sem organization_id confiado ao cliente e sem service role no browser.
- [x] Bootstrap administrativo Organization + Membership + profile legado preparado como função transacional service-role-only.
- [x] Endpoint server-only preparado com invite Auth + compensação deleteUser se o bootstrap SQL falhar.
- [x] Admin client marcado `server-only`; nenhuma service role foi exposta ou gravada no Git.
- [x] Chicken-and-egg do primeiro admin resolvido por runbook de cerimônia operacional única; nenhum endpoint público/bypass permanente foi criado.
- [x] Verificação read-only do primeiro bootstrap criada.
- [x] Estado live reconfirmado antes do bootstrap: 0 auth.users, 0 organizations, 0 memberships, 0 profiles.
- [x] Human Gate autorizado pelo usuário e `admin_org_bootstrap_v0` aplicado live com sucesso.
- [x] Pós-DDL verificado: RLS ativo em platform tables; bootstrap SECURITY DEFINER não executável por anon/authenticated e executável por service_role.
- [x] Security advisor pós-apply: nenhum novo WARN do bootstrap; permanece apenas WARN legado de `get_user_organization_id()`. INFO de RLS sem policy nas platform tables é intencional porque somente service_role tem grants.
- [x] Customer 360 corrigido contra schema live: constraint real `unique_cpf_per_organization` e `original_source` sem conflar oportunidade.
- [x] Product Catalog endurecido: FK composta `(product_id, modality_id)` impede modalidade de produto diferente.
- [x] Grants `service_role` do catálogo/rotas/tabelas agora são explícitos e cobertos pelo contrato pós-DDL.
- [x] Agreement agora pertence a Bank; FK composta impede rota usar convênio de banco diferente.
- [x] ProductTableVersion ganhou trigger de defesa em profundidade: snapshot comercial não muda depois de sair de draft.
- [x] `proposals_v2_org_id_key` movido para a migration dona da entidade (Simulation/Proposal).
- [x] Simulation/Proposal ganhou grants explícitos de service_role.
- [x] Checklist items só podem ser inseridos/alterados por authenticated enquanto o template pai estiver draft.
- [x] Document Vault ganhou grants explícitos de service_role.
- [x] ProposalDocumentRequirement agora preserva snapshot estrutural via trigger; UPDATE não pode reescrever proposta/tipo/label/required original.
- [x] Campos de waiver agora só podem existir quando status=`waived`.
- [x] Pipeline não recria mais a chave composta de Proposal; ownership permanece na migration Proposal.
- [x] OperationalCase ganhou FK composta Stage+canonical_state, impedindo estado técnico divergente do stage escolhido.
- [x] Pipeline ganhou grants service_role explícitos; operational_events permanece sem UPDATE/DELETE até para service_role neste V0.
- [x] Revisão adversarial integral encontrou e corrigiu delimitadores PL/pgSQL inválidos antes de apply.
- [x] FKs staged receberam índices adicionais para evitar regressão de unindexed foreign keys.
- [x] PIX→BankAccount agora prova mesmo tenant E mesmo Customer; primários de conta/PIX limitados a um por Customer.
- [x] Customer timeline permanece append-only também para service_role.
- [x] Proposal ligada a Simulation agora exige mesmo Customer + ProductTableVersion.
- [x] Proposal exige ProductTableVersion publicada e snapshot comercial fica imutável após sair de draft.
- [x] CustomerDocument virou evidência imutável por versão; correção estrutural exige nova versão.
- [x] Requirement validated exige documento vinculado; waiver exige aprovador atual com role admin/manager/supervisor.
- [x] DigitizationJob ganhou gate transacional: Proposal ready_for_digitization + todos documentos obrigatórios validated/waived.
- [x] Tenant admin deixou de poder provisionar tenants: endpoint agora exige platform_administrator ativo.
- [x] Bootstrap de tenant agora exige platform actor e grava audit event append-only na mesma transação DB.
- [x] Advisors live reconfirmados sem mudança persistente: 1 WARN legado SECURITY DEFINER; infos de índices não usados em DB vazio; migrations live continuam somente as 4 previamente aplicadas.
- [x] Branch está 116 commits à frente de main e 0 atrás no último compare; nenhum CI status disponível para o HEAD consultado.

## Próxima execução
1. Construir harness A/B autenticado para validar isolamento real entre dois tenants sem usar dados de clientes.
2. Preparar migration separada das policies legadas para membership, sem aplicá-la antes do gate A/B.
3. Corrigir índices de FKs legadas de forma aditiva.
4. Customer 360 está tecnicamente preparado; manter migration não aplicada até o gate A/B.
5. Catálogo V0 revisado e Simulation/Proposal V0 preparado.
6. Document Vault/checklist V0 preparado e revisado.
7. Internal Digitization + Operational Pipeline V0 preparado.
8. Revisão integrada e manifesto concluídos.
9. Gate A/B autenticado continua sendo o bloqueio real para aplicar a cadeia.
10. Auth/Login/UI revisado e caminho fail-closed implementado.
11. Bootstrap administrativo preparado; migration ainda não aplicada e endpoint não deployado.
12. Contrato e runbook do primeiro admin concluídos; banco continua vazio.
13. Próximo gate exige identidades Auth controladas reais (e-mails), que não serão inventadas nem criadas sem dados válidos.
14. Revisão CPF/Product↔Modality/service_role concluída.
15. Bank↔Agreement e imutabilidade de ProductTableVersion corrigidos.
16. Document checklist child immutability e ownership da chave Proposal corrigidos.
17. Requirement snapshots e Pipeline grants/coerência Stage↔State corrigidos.
18. Revisão estática/adversarial integral concluída e achados corrigidos.
19. BLOQUEIO REAL: para validar SQL contra Postgres sem tocar produção é necessário ambiente/branch de banco de teste; criar Supabase Branch tem custo potencial e exige confirmação.
20. BLOQUEIO REAL: Gate A/B exige identidades Auth controladas reais e registro inicial de platform_administrator; banco live continua sem usuários.
21. Após Human Gate: aplicar somente bootstrap admin, provisionar operador + dois tenants de teste, executar A/B; só com 100% passar para cadeia staged.

## Gates
Não alterar `main`. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Não fabricar dados de clientes. Operação irreversível, gasto, billing/money ou mudança externa relevante exige Human Gate.


## Live gate 2026-09-18
- Platform Admin autorizado e ativado: josicleuton.braga@gmail.com.
- Tenant A e Tenant B provisionados atomicamente via bootstrap_organization_admin; audit events gravados.
- Gate A/B membership: A vê somente A e helper(A)=true/helper(B)=false; B vê somente B e helper(B)=true/helper(A)=false; anon sem SELECT; nenhuma policy INSERT/UPDATE/DELETE de membership, tentativa cross-tenant INSERT bloqueada por RLS.
- Legacy RLS membership migration aplicada live após gate A/B.
- Security advisor: warning legado SECURITY DEFINER removido; novo warning operacional: leaked password protection disabled. Platform tables sem policies aparecem como INFO e permanecem service-role-only por design.
- Proposal staged corrigida para não bloquear atualização histórica quando ProductTableVersion publicada depois vira superseded/expired.
- Próximo Human Gate: aplicação live das migrations do vertical slice permanece ação DDL de produção separada; não inferir autorização do gate anterior.


## Vertical Slice V0 live — 2026-09-18
- Human Gate autorizado pelo usuário.
- Aplicadas live, em ordem: Customer 360, Product Catalog V0, Simulation/Proposal V0, Document Vault V0, Digitization/Operational Pipeline V0.
- Contracts SQL de cada domínio executados após a respectiva migration; DDL aplicado sem erro.
- Antes do Pipeline, gate de documentos foi endurecido: checklist publicado sem requirements instanciados agora falha fechado (commit ce919970).
- Advisor pós-apply detectou ERROR de RLS desativado nas 6 tabelas globais de catálogo/document types; corrigido imediatamente com migration post-apply (commit 9d925654).
- Também adicionados os 6 índices de FKs apontados pelo advisor.
- Advisor final: 0 ERROR de segurança; 1 WARN operacional (Leaked Password Protection Disabled); 2 INFO intencionais nas tabelas platform service-role-only. Performance: 0 unindexed_foreign_keys; unused indexes esperados em banco recém-criado + Auth connection strategy INFO.
- Verificação final: todas as 24 tabelas do vertical slice consultadas estão com RLS=true e policies presentes.
- Vertical Slice V0 database foundation concluído. Próxima frente: application/domain services + UI + storage policies + state-machine/RBAC hardening antes de produção real.


## Application slice autonomous pass — 2026-09-18
- Implementado App Shell autenticado com contexto tenant fail-closed e navegação.
- Dashboard consulta contagens reais de clientes, propostas, fila de digitação e casos operacionais sob RLS.
- Customer 360: listagem + cadastro básico server action + timeline; validação de nome/CPF/e-mail.
- Propostas: listagem real de snapshots/status/valores.
- Operação: listagem real de casos e estado canônico.
- Catálogo: visibilidade de bancos/providers/rotas/tabelas.
- UI continua na branch architecture/corban-os-master-v2; main intocada; branch 142 commits ahead / 0 behind.
- Não há CI/status de build disponível no GitHub e a conexão Vercel atual não retorna teams/projetos; portanto não declarar build aprovado nem preview publicado.
- Revisão adversarial encontrou falta de atomicidade no cadastro Cliente + Timeline. Migration 20260918_domain_primitives_v0.sql foi preparada no Git para resolver em uma transação SECURITY INVOKER.
- BLOQUEIO/HUMAN GATE: aplicar domain_primitives_v0 no Supabase live é novo DDL de produção. Após autorização, aplicar migration, validar grants/RLS/rollback e migrar server action para RPC atômica. Depois continuar state machines/RBAC/Storage sem publicar produção sem novo gate.
