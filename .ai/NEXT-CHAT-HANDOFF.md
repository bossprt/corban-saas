# CORBAN OS — NEXT CHAT HANDOFF

Data do handoff: 20/09/2026, fim da sessão.
Fonte de verdade operacional: este arquivo + `.ai/CURRENT-TASK.md` + `CORBAN-CURRENT-STATE.md`.
Branch de trabalho: `architecture/corban-os-master-v2`.
Nunca trabalhar em `main`.

## Regra de execução do Owner
- Antes de mudança relevante: revisão tripla obrigatória — completude, crítica/adversarial, execução/validação.
- ChatGPT executa diretamente tudo que puder com GitHub/Supabase/Vercel.
- Claude Code somente quando houver necessidade real de ambiente local/capacidade indisponível.
- Quando usar Claude: uma tarefa longa, branch própria, leitura seletiva, economizar tokens e reutilizar ferramentas/plugins locais.
- DDL LIVE, secrets, gasto, publicação irreversível ou mudança destrutiva exigem Human Gate explícito.
- Decisões relevantes devem sempre ser persistidas nos arquivos de handoff antes de encerrar a sessão.

## Arquitetura macro
```
CORBAN
├── SmartMatch
└── DeskcommCRM
```
Corban é o guarda-chuva principal. SmartMatch e DeskcommCRM podem continuar em repositórios/infrastruturas separadas, integrados por APIs/eventos/identidades e nunca por acoplamento inseguro de banco/secrets.

## Estado funcional consolidado

### Seller / SUB / Fatores
LIVE:
- `20260920235725 seller_commercial_profile_v1`
- `20260920235731 commercial_factors_v1`

Implementado:
- Grupo de Vendedor separado de Grupo de Comissão;
- Vendedor PF/PJ/SUB;
- regra SUB versionada;
- fator diário/fixo;
- histórico/versionamento;
- UI de Vendedores e Fatores.

### Componentes de comissão + Tipos de Contrato
LIVE:
- `component_commissions_v1`
- `tenant_contract_types_v1`
- `post_seller_factors_fk_indexes_v1`

Tipos globais atuais:
- Novo
- Refinanciamento
- Compra de Dívida
- Portabilidade
- Refin/Portabilidade

Componentes:
- À Vista
- Diferido
- Bônus
- Bônus 2
- Bônus 3
- Plástico
- Seguro fixo

Suporte a % e R$, regra por Grupo de Comissão, imposto/desconto e escopo por organização/instituição/convênio/tabela.

### Smart Commercial Import
LIVE:
- `20260921003829 smart_commercial_import_v1`
- `20260921021027 smart_import_policy_scope_guard_v1`

**NÃO REAPLICAR.**

Formatos:
- CSV
- XLSX
- XLS legado BIFF
- PDF textual estruturado
- PDF escaneado/ambíguo é recusado; sem OCR automático.

Fluxo:
`arquivo -> leitura estrutural -> parser comercial -> mapeamentos -> prévia -> regra -> confirmação -> RPC atômica -> tabela em rascunho`

Proteções:
- percentuais XLSX ambíguos falham fechado;
- Plástico sem unidade clara falha fechado;
- Tipo de Contrato externo exige mapeamento explícito;
- cabeçalhos desconhecidos podem ser mapeados manualmente;
- preview/apply usam os mesmos mapas;
- política de comissão fora do escopo Banco/Convênio/Tabela é recusada também pelo banco;
- tabela nunca é publicada automaticamente;
- cálculos financeiros determinísticos, sem IA e sem float.

### Smart Import — regra sugerida
O sistema sugere a política ativa mais específica:
`Tabela > Convênio > Instituição > Global`.
Empate no mesmo nível exige escolha humana. Nunca desempatar política financeira silenciosamente.

### Repasse 1/2/3
Estado consolidado:
- nunca inferir Repasse 1 = Corretor etc.;
- usuário pode mapear explicitamente slot -> Grupo de Comissão;
- também informa a semântica: valor final pago ou % da comissão recebida;
- unidade explícita % ou R$;
- mapeamento parcial continua fail-closed;
- pode ignorar slots e usar somente política interna;
- valores externos servem para comparação/evidência, não substituem política interna;
- preview compara externo × interno com estados de divergência;
- último build funcional dessa onda registrado como READY em `f165112f4e8aa1370d193c83e3b4b0b4bad4a4f6`.

## Estado financeiro/segurança
- comissão continua fail-closed para supervisor+ via política central `canViewCommission` + RLS;
- `/app/comercial` foi auditado e voltou a obedecer `canViewCommission`;
- Security Advisor pós última migration LIVE: nenhum WARN/ERROR novo;
- permanecem apenas 2 INFO históricos em tabelas exclusivas de Platform Admin.

## Seller/SUB + proposta/financeiro — estado LIVE
LIVE:
- `20260921025320 seller_sub_proposal_snapshot_v1`.

Aplicação concluída:
- Vendedor/SUB selecionável em proposta draft por RPC governada;
- rota comercial pode ser congelada pela proposta;
- snapshot SUB/empresa por componente visível apenas supervisor+;
- expected commission usa company share congelado;
- Vercel READY para o fluxo de freeze da UI no commit `97bf2548f360429a2f52c66af385295d04e5ba06`.

## Proposal/Financial integrity hardening — LIVE
LIVE:
- `20260921031621 proposal_financial_integrity_hardening_v1`.

Pós-apply:
- contract passou no banco real;
- freeze exige regra publicada e vigente também no banco;
- expected/evidence atualizam conciliação automaticamente nos caminhos governados;
- UPDATE/DELETE removidos de authenticated/anon nos snapshots comerciais imutáveis;
- Security Advisor continua sem WARN/ERROR novo, apenas 2 INFO históricos de Platform Admin.

Aplicação financeira:
- validação de valor de reversão e comparação de saldo reversível foram ajustadas para não usar ponto flutuante;
- commit funcional em validação/READY no Vercel antes do encerramento desta sessão.

## Simulation lifecycle V1 — LIVE
LIVE:
- `20260921032402 simulation_lifecycle_v1`.

Pós-apply:
- contract passou;
- `selected` é terminal;
- fechamento governado somente `calculated -> cancelled|expired` para supervisor/manager/admin;
- UI de Cancelar/Expirar está READY no Vercel.

## Organization direct-write privilege hardening V1 — LIVE
LIVE:
- `20260921033720 organization_direct_write_privilege_hardening_v1`.

Pós-apply:
- contract passou;
- authenticated/anon sem INSERT/UPDATE/DELETE em `organizations`;
- authenticated mantém SELECT;
- bootstrap segue exclusivo do fluxo Platform Admin;
- Security Advisor sem WARN/ERROR novo.

## Seller commission visibility + access governance — LIVE / CLOSED
Owner policy:
- seller = own commission only;
- supervisor = explicitly supervised sellers only;
- manager/admin = all seller commissions;
- company Finance/ledger = manager/admin only.

LIVE:
- `20260921041041 seller_commission_visibility_scope_v1`;
- `20260921041520 seller_access_governed_write_hardening_v1`.

Application:
- `/app/comissoes` is the scoped seller commission surface;
- seller user binding and supervisor assignments are managed under Cadastros > Vendedores;
- Financeiro is manager/admin only;
- seller commission snapshot is immutable and separate from company financial events;
- ambiguous payout resolves to `unavailable`, never an estimate.

Security:
- direct user binding/supervision Data API writes are blocked unless inside governed RPC context;
- RLS helper enforces own/supervised/all scope;
- post-apply contracts passed;
- Security Advisor has no new WARN/ERROR.

Standing authorization:
Owner authorized future LIVE DDL without a new prompt only when strictly necessary to complete this same seller-commission visibility rule, and only after rollback contract passes. Any unrelated DDL/destructive/external action still requires Human Gate.

## NEXT REAL GATE — external pilot readiness
Verified:
- production login is live at `https://corban-saas.vercel.app/login` (HTTP 200);
- Smart Promotora Ltda. exists and is active; never recreate it;
- banks=34; providers=0; agreements=0; products=0; document_types=0.

External actions still required before a real human pilot:
1. Supabase Auth URL/SMTP/password configuration using `https://corban-saas.vercel.app` as the current production origin;
2. confirm/set Vercel `NEXT_PUBLIC_SITE_URL=https://corban-saas.vercel.app`;
3. provide/load REAL reference-catalog providers, agreements, products/modalities and document types;
4. then run one real invitation/recovery/browser acceptance pass.

Worker is NOT a current blocker for browser pilot and stays disabled until a real provider is homologated. Enabling it later requires `INTEGRATION_WORKER_SECRET` + scheduler and is a separate external gate.

No unrelated DDL is pending. Do not invent catalog or business/economic data and do not create fake LIVE records solely for tests.

## Ambiente
- GitHub: `bossprt/corban-saas`
- branch: `architecture/corban-os-master-v2`
- Supabase: projeto `nhjfrcttzxnphhizlnmc`
- Vercel: projeto `corban-saas`
- URL pública: `https://corban-saas.vercel.app`

## Commit/head no momento do handoff
Branch HEAD deve ser conferido no GitHub ao retomar; não confiar em SHA histórico.

## Regra de retomada
No novo chat:
1. ler este arquivo;
2. ler apenas o final de `.ai/CURRENT-TASK.md` e `CORBAN-CURRENT-STATE.md`;
3. não repetir migrations LIVE;
4. não refazer OAuth, setup ou testes já concluídos;
5. continuar da próxima fronteira autônoma registrada acima; não reaplicar migrations LIVE.


## OWNER VISUAL CHECK — production confirmed
- Owner confirmed Corban OS is online and current updates are visible in production.
- Smart Promotora Ltda. appears in the UI.
- Updated navigation/dashboard is visible, including Comissões.
- SMTP/Resend intentionally deferred; do not configure until Owner resumes this gate.


## Incident fix — seller group creation regression
Owner reported that creating a Seller Group returned generic failure and therefore seller creation was blocked.
Root cause verified LIVE: shared trigger `guard_seller_catalog_row()` was used by both `commercial_sellers` and `seller_groups`, but the seller-access hardening dereferenced `NEW.user_id` / `OLD.user_id`. `seller_groups` has no `user_id`, causing the insert to fail.

Fix:
- prepared `20261020_seller_catalog_shared_trigger_regression_fix_v1.sql` + security contract;
- changed user binding inspection to safe `to_jsonb(NEW/OLD)->>'user_id'` so the shared trigger works on both tables;
- rollback harness as authenticated Smart admin proved: Seller Group insert works, seller insert works, direct seller user binding remains blocked;
- applied LIVE as `20260921044435 seller_catalog_shared_trigger_regression_fix_v1` under standing authorization for the same seller-access wave;
- post-apply contract passed;
- Security Advisor unchanged: no new WARN/ERROR, only 2 historical Platform Admin INFO.

No rollback-test business rows persisted in LIVE.


## Seller access bootstrap V1 — PREPARED / NOT LIVE
Owner requirement:
- seller/corretor should not require a second manual "login binding" step;
- when system access is desired, seller creation and access invitation must be one business flow;
- seller-linked login must be role `agent` and can see only own seller commission;
- supervisor/manager/admin scopes remain unchanged.

Prepared:
- `supabase/migrations/20261021_seller_access_bootstrap_v1.sql`;
- `tests/security/seller-access-bootstrap-contract.sql`.

Design:
- `organization_invitations.seller_id` links access invitation to seller;
- `create_seller_with_access(...,p_email)` atomically creates seller + agent invitation when email is supplied;
- access can remain absent for external sellers by passing null email;
- invite acceptance automatically binds `commercial_sellers.user_id` to the verified Auth user;
- existing active non-agent member cannot be silently reused as seller login (`seller_access_requires_agent_role` fail-closed);
- manual `set_seller_user` now accepts only active agent membership;
- seller audit event types are added to the existing append-only admin audit allow-list;
- seller user/supervision audit writes use governed membership context.

Rollback validation:
- several pre-LIVE defects were found and corrected: audit gate context, audit event CHECK, SQL dollar quoting, ambiguous column reference;
- final full harness passed: create seller + create linked agent invitation + simulated service-role acceptance + automatic seller/user binding + own-commission RLS access;
- all test changes rolled back; no synthetic LIVE rows persisted.

Important deployment sequencing:
- do NOT switch production UI to `create_seller_with_access` until this migration is LIVE;
- after LIVE apply, update seller form to default `Criar acesso ao sistema` ON, require email when checked, call new RPC, and attempt invitation email without failing seller creation when SMTP is unavailable.

**Human Gate required before applying this new DDL LIVE.**


## Seller access bootstrap V1 — LIVE + UI migration in progress
Applied LIVE as `20260921050521 seller_access_bootstrap_v1` after explicit Owner authorization.
Post-apply contract passed; Security Advisor unchanged (no new WARN/ERROR; 2 historical Platform Admin INFO only).

Authoritative seller access rule:
- seller/corretor with system access is always an `agent` membership;
- seller can see only own seller commission via scoped RLS;
- supervisor sees only explicitly supervised sellers;
- manager/admin see all seller commissions;
- company Finance remains manager/admin only.

New business flow:
- seller form defaults to `Criar acesso ao sistema` ON;
- e-mail is required only when access is requested;
- `create_seller_with_access` atomically creates seller + linked agent invitation;
- invitation acceptance automatically binds the verified Auth user to `commercial_sellers.user_id`;
- seller record remains valid even if invitation e-mail cannot be sent (SMTP currently deferred);
- external seller can be created without system access by unchecking access;
- old manual login-binding UI is removed from the normal path; access panel now reports active/pending/no-access state and keeps supervisor management.

Application commits include unified seller creation and automatic access state UI. Latest application HEAD before documentation: `afe22a296ec21baedad0384e017cc41333244920`; Vercel build was still BUILDING at last check.


## Seller full profile + payout readiness V1 — LIVE
Applied LIVE as `20260921052901 seller_full_profile_payout_readiness_v1` after explicit Owner authorization.
Post-apply contract passed. Security Advisor unchanged: no new WARN/ERROR; only the 2 historical Platform Admin INFO findings.

Authoritative product rule:
- Corban OS seller registry must be equal-or-better than useful 2Tech seller registration capability, never worse;
- simplification is allowed only when the OS automates/normalizes the same capability without losing information;
- seller registration must support operations, access control, supervision, production, commission and payout readiness.

LIVE seller data model now includes:
- seller_profiles: legal/trade name, e-mail, phone, WhatsApp, birth/opening date, identity/registration, issuer, occupation, notes;
- seller_addresses: versioned current + historical address;
- seller_payment_accounts: versioned bank/Pix payout destination, holder, verification status and effective dates;
- seller_certifications: issuer, number, issue/expiry, status and notes;
- RLS: manager/admin manage; seller can see own profile/payment; supervisor can see supervised seller profile but NOT payout account;
- all writes go through governed RPCs; direct writes are trigger-blocked;
- payment destination replacement closes old version instead of overwriting history.

Application UX:
- /app/cadastros/vendedores remains focused on NEW seller registration and seller-group creation;
- button opens /app/cadastros/vendedores/consulta;
- consultation is compact: search name/CPF-CNPJ + active status + one summary row per seller + Abrir cadastro;
- each seller has dedicated /app/cadastros/vendedores/[id] profile page;
- profile is separated into blocks: Identificação comercial, Dados cadastrais/contato, Endereço, Acesso/supervisão, Dados para pagamento de comissão, Produção/comissão, Certificações;
- payment account history is visible only to manager/admin;
- production block shows seller-linked proposals and calculated seller commission, explicitly warning calculated != paid;
- new seller creation redirects to the dedicated profile page so the operator can complete the full registration immediately.

Important remaining domain gap:
- payout readiness is now in place, but final commission-payment settlement/reporting still requires its own governed payout batch/payment ledger. Do NOT infer `paid to seller` from calculated commission or company financial events.


## Seller operations identity + seller UX V1 — LIVE / app rollout
Applied LIVE:
- `20260921055340 seller_operations_identity_v1`
- regression patch under same authorized wave: `seller_branch_default_regression_fix_v1` (new sellers default to active Matriz when branch is omitted by older RPCs).

Database capabilities now LIVE:
- organization_branches with one Matrix per organization and optional branches;
- commercial_sellers.branch_id required and backfilled to Matrix;
- commercial_sellers.commission_payment_frequency = daily|weekly|monthly (default monthly);
- seller_bank_aliases for deterministic external bank/user identity;
- normalized imports accept producerExternalUser and store resolved_seller_id;
- import match candidates carry seller_id when an alias resolves;
- no guessing: unknown alias stays unresolved/human-required.

Application UX implemented on branch:
- Cadastros -> Vendedores redirects to compact consultation/list as module entrypoint;
- Cadastrar vendedor opens /app/cadastros/vendedores/novo;
- new seller screen is a single structured form with commercial identity, Matrix/Branch, payment frequency, profile/contact, address, direct external login/password, payout account and initial bank-user alias;
- password goes directly to Supabase Auth admin createUser and is never persisted in seller tables/logs;
- Auth user is email-confirmed server-side for this controlled admin-created access and invitation acceptance links it automatically to the seller as agent;
- seller profile edit includes Matrix/Branch, payment frequency and bank-user aliases;
- Produção e comissão removed from seller registry; that belongs to seller external area and manager/supervisor reports;
- Matriz e filiais has a dedicated registrations page; no branch-management block pollutes seller registration;
- 2Tech/generic import adapters now extract producerExternalUser from common columns such as Usuário Banco, Usuário, Login, Operador and Vendedor.

Security:
- seller direct login remains agent-only and own-commission scoped by existing RLS;
- passwords remain Auth-only and hashed by Supabase; never persisted as plaintext;
- seller alias resolution is tenant-scoped and deterministic;
- Security Advisor after DDL remained unchanged: no new WARN/ERROR, only 2 historical Platform Admin INFO.


### Seller operations rollout final validation
Final LIVE migration versions:
- 20260921055340 seller_operations_identity_v1
- 20260921055553 seller_branch_default_regression_fix_v1

Final application build:
- HEAD `27db75599047de8eb9f7d772fab9dd09254a483b`
- Vercel production deployment READY.

Build fixes applied during validation:
- corrected branch-management action to use authenticated `user.id` from app context;
- removed duplicate `producerExternalUser` property in generic import adapter;
- made `producerExternalUser` optional at the TypeScript contract boundary for backward compatibility while new adapters still populate it when present.


## Commission Groups — authoritative component-limit model
Final rule clarified by Owner:
- Commission Group is NOT the seller's final payout percentage.
- Commission Group defines, per received commission component, how much of 100% received by the organization may enter the calculation base for that group.
- Components: upfront, deferred, bonus_1, bonus_2, bonus_3, plastic, insurance_fixed.
- 100% = the full amount received for that component may be used as base.
- 0% = that component is not repassed for that group.
- Intermediate values (e.g. 90%) cap the usable received amount for that component.
- A later table/rule may use any value from 0 up to that group/component ceiling; values above the ceiling must be rejected, not silently capped.
- A table/rule may always choose 0/exclude even if the group ceiling is greater than 0.
- Direct calculation over production is forbidden for Commission Groups; basis is always commission received by the organization.
- Examples such as seller receiving 65% belong to another layer and must not be embedded in Commission Group semantics.

LIVE migrations:
- 20260921153515 commission_group_component_limits_v1
- 20260921153627 commission_group_component_limits_security_hardening_v1
- commission_group_component_exclude_semantics_fix_v1 applied under the same authorized wave

Security:
- configuration RPC is SECURITY INVOKER;
- direct writes to group-component limits are blocked outside governed RPC context;
- Security Advisor returned to prior state: only 2 historical INFO findings for Platform Admin, no new WARN/ERROR.

UI:
- /app/comercial/grupos now shows Name + per-component percentages;
- existing Basic group remains Configuração pendente until Owner explicitly fills values; no percentages were invented;
- each component uses 0..100 with clear meaning;
- back button returns to /app/cadastros.

Current verified green HEAD: fb16360599059fc4ba91587c279cf36ec32e2853 (Vercel SUCCESS).
