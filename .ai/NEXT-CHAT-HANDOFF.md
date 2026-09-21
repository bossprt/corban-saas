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

## HUMAN GATE ATUAL — PRÓXIMA DECISÃO
Preparada e **NÃO LIVE**:
- `20261014_seller_sub_proposal_snapshot_v1.sql`
- `tests/security/seller-sub-proposal-snapshot-contract.sql`
- `docs/SELLER-SUB-PROPOSAL-SNAPSHOT-V1.md`

Objetivo:
ligar Vendedor/SUB à proposta e à receita/comissão esperada com snapshot imutável.

Modelo preparado:
- proposta draft recebe `seller_id` por RPC governada;
- vendedor só muda antes do freeze comercial;
- freeze congela seller/category/seller group;
- commission group só aparece em snapshot protegido supervisor+;
- SUB resolve a versão publicada da regra por componente, fallback `all`;
- SUB sem regra publicada falha fechado;
- fórmula:
  `gross component × upstream/network share × seller_company_share_pct / 100`;
- não-SUB = company share 100%;
- SUB 100% = empresa 0%;
- SUB 90% = empresa 10%;
- rede/split e SUB são dimensões independentes;
- histórico financeiro já congelado nunca é reescrito.

Validação já feita:
- migration + contract passaram em `BEGIN ... ROLLBACK`;
- não consta em `list_migrations`;
- LIVE atual tinha 0 propostas, 0 component snapshots, 0 commission_expected, 0 SUB sellers e 0 regras SUB publicadas no precheck;
- portanto não existe backfill econômico atual para reinterpretar.

**Novo chat deve começar perguntando somente se o Owner autoriza aplicar `20261014_seller_sub_proposal_snapshot_v1` LIVE, a menos que o Owner dê outra instrução.**

## Ambiente
- GitHub: `bossprt/corban-saas`
- branch: `architecture/corban-os-master-v2`
- Supabase: projeto `nhjfrcttzxnphhizlnmc`
- Vercel: projeto `corban-saas`
- URL pública: `https://corban-saas.vercel.app`

## Commit/head no momento do handoff
Branch HEAD observado antes deste handoff: `3ea063e8cf197471bc3efeaf90fb9661e81bf8ec`.

## Regra de retomada
No novo chat:
1. ler este arquivo;
2. ler apenas o final de `.ai/CURRENT-TASK.md` e `CORBAN-CURRENT-STATE.md`;
3. não repetir migrations LIVE;
4. não refazer OAuth, setup ou testes já concluídos;
5. continuar do Human Gate de Seller/SUB proposal snapshot.
