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

## Próxima execução
1. Construir harness A/B autenticado para validar isolamento real entre dois tenants sem usar dados de clientes.
2. Preparar migration separada das policies legadas para membership, sem aplicá-la antes do gate A/B.
3. Corrigir índices de FKs legadas de forma aditiva.
4. Iniciar schema Customer 360 após o gate de tenant.
5. Seguir Bank/Product/Table → Simulation → Proposal → Documents → Digitization → Pipeline.

## Gates
Não alterar `main`. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Não fabricar dados de clientes. Operação irreversível, gasto, billing/money ou mudança externa relevante exige Human Gate.
