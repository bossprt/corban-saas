# CURRENT TASK — CORBAN OS V2

**Atualização:** 18/09/2026
**Branch:** `architecture/corban-os-master-v2`

## Último estado comprovado
- Preview Vercel abre login e autenticação real foi confirmada pelo usuário.
- Build Vercel confirmado SUCCESS no commit `3718b230`.
- App autenticado possui Dashboard, Clientes, Catálogo, Simulações, Propostas, Documentos e Operação.
- Tenant context continua fail-closed; main intocada.
- Live DB foundation do Vertical Slice permanece saudável; nenhuma DDL nova desta execução foi aplicada.

## Implementado nesta execução
- UI de simulação usando apenas cliente do tenant + ProductTableVersion publicada.
- Proposal detail com snapshot/checklist/operação.
- Document Vault read-only.
- Mesa operacional com fila de digitação + casos.
- CPF checksum server-side.
- Caminho não-atômico de criação de proposta removido.

## Preparado e aguardando Human Gate de DDL
1. `supabase/migrations/20260918_vertical_slice_domain_workflow_v0.sql`
   - unique proposal/simulation;
   - selected simulation immutable;
   - proposal state transition guard;
   - atomic `create_proposal_from_simulation(uuid)`;
   - `prepare_proposal_documents(uuid)`;
   - transactional `send_proposal_to_digitization(uuid)`.
2. `supabase/migrations/20260918_document_storage_rls_v0.sql`
   - private `corban-documents` bucket;
   - 15 MiB + PDF/JPEG/PNG/WebP;
   - tenant/customer path isolation;
   - authenticated SELECT/INSERT; no UPDATE/DELETE.
3. Post-apply contract: `tests/security/vertical-slice-workflow-contract.sql`.

## Live inventory
Read-only query em 18/09/2026: 0 banks, 0 routes, 0 product tables, 0 published versions, 0 document types, 0 operational stages, 0 clients, 0 simulations, 0 proposals. O tenant de teste autenticado está vazio; nenhum seed foi aplicado.

## Próxima execução após Gate
- aplicar as duas migrations preparadas em sequência controlada;
- executar contract + advisors;
- somente após sucesso, ligar UI aos RPCs atômicos;
- preparar/configurar dados de catálogo e stages sem inventar dados comerciais;
- implementar upload documental sobre Storage privado e link/validation workflow;
- validar ponta a ponta em Preview.

## Human Gate atual
É necessária autorização explícita para aplicar as duas novas migrations DDL no Supabase live. Nenhuma outra ação do usuário é necessária antes disso.
