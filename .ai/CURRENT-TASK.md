# CURRENT TASK — CORBAN OS V2

**Atualização:** 18/09/2026 07:26–07:40 (America/Rio_Branco)
**Branch:** `architecture/corban-os-master-v2`

## Estado comprovado nesta execução
- Human Gate recebido e as migrations autorizadas foram aplicadas live:
  - `vertical_slice_domain_workflow_v0` — versão live `20260918122710`;
  - `document_storage_rls_v0` — versão live `20260918122715`.
- Contract `tests/security/vertical-slice-workflow-contract.sql` executado sem exceções.
- Revisão adversarial encontrou fail-open em checklist ausente/zero itens; correção de segurança aplicada imediatamente dentro do escopo autorizado:
  - `vertical_slice_workflow_fail_closed_patch` — versão live `20260918122937`.
- Supabase advisor após apply: 0 ERROR; permanece WARN de leaked-password protection e 2 INFO intencionais nas tabelas platform service-role-only.
- Preview Vercel confirmado SUCCESS no commit `c9136e5f`, cobrindo UI de upload/link/validação documental.

## Vertical Slice funcional agora conectado
- Login/Tenant: real.
- Customer 360: cadastro atômico + CPF checksum.
- Catálogo: leitura; dados comerciais continuam vazios.
- Simulação: criação por cliente + versão publicada.
- Simulação → Proposta: RPC atômica live `create_proposal_from_simulation`.
- Proposta: detalhe + snapshots.
- Documentos: bucket privado live; upload PDF/JPEG/PNG/WebP até 15 MiB; hash SHA-256; versionamento; vínculo ao requisito; validação supervisor+ na aplicação.
- Checklist: RPC live `prepare_proposal_documents`, agora fail-closed sem template publicado ou sem itens.
- Envio para digitação: RPC transacional live `send_proposal_to_digitization`.
- Mesa: fila + casos operacionais.

## Pendências preparadas antes do próximo Gate
1. `20260918_operational_state_machine_v0.sql`
   - estado operacional transacional;
   - sincroniza case/job/proposal/timeline;
   - adiciona terminal `rejected` à proposta;
   - bloqueia `paid` manual: exige futura fonte financeira confirmada;
   - decisões approved/rejected/cancelled exigem supervisor+.
2. `20260918_rbac_hardening_v0.sql`
   - restringe escrita de catálogo para admin/manager;
   - checklist para supervisor+;
   - stages para admin/manager;
   - lifecycle de evidência para supervisor+;
   - endurece transitions/validação documental no banco, evitando bypass pela REST API.
3. Contracts preparados:
   - `tests/security/operational-state-machine-contract.sql`
   - `tests/security/rbac-hardening-contract.sql`

## Dados live
O banco continua sem catálogo comercial e sem dados de operação: não foi inventado nem inserido seed comercial. Isso impede um E2E real Simulação→Pipeline com dados persistentes até existir catálogo/tabela/checklist/stages válidos.

## Próximo passo após autorização
- aplicar Operational State Machine + RBAC hardening;
- executar os dois contracts e advisors;
- conectar controles de transição da Mesa à RPC;
- revisar Vercel;
- preparar onboarding/configuração de catálogo/stages/checklists sem inventar condições comerciais;
- parar somente no próximo Human Gate real.

## Human Gate atual
Aplicação live de duas novas migrations DDL preparadas: `20260918_operational_state_machine_v0.sql` e `20260918_rbac_hardening_v0.sql`.
