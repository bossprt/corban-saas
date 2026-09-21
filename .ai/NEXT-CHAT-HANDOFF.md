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
