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
11. Preparar endpoint/ação administrativa atômica Organization + Membership, sem expor service role e sem executar criação real ainda.
12. Depois criar duas identidades controladas pelo fluxo suportado, executar gate A/B e só então aplicar a sequência.

## Gates
Não alterar `main`. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Não fabricar dados de clientes. Operação irreversível, gasto, billing/money ou mudança externa relevante exige Human Gate.
