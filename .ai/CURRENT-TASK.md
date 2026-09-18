# CURRENT TASK — CORBAN OS V2

**Atualização:** 18/09/2026
**Branch:** `architecture/corban-os-master-v2`

## Concluído nesta execução
- Aplicadas live, com autorização explícita:
  - `operational_state_machine_v0`;
  - `rbac_hardening_v0`.
- Ambos os post-apply contracts executaram sem exceção.
- Advisor detectou exposição RPC do helper SECURITY DEFINER de RBAC; correção adversarial aplicada live como `rbac_helper_exposure_patch`. Novo advisor removeu esse WARN.
- Security advisor atual: 0 ERROR; 1 WARN de leaked-password protection; 2 INFO intencionais das tabelas platform service-role-only.
- Mesa conectada à RPC `transition_operational_case` para digitação → enviado → aguardando banco → aprovado/rejeitado/cancelado.
- `PAID` continua deliberadamente bloqueado para ação manual; futura verdade financeira precisa de fonte confirmada.
- Página `/app/configuracao` adicionada para mostrar prontidão real do tenant.

## Estado do Vertical Slice
Login/Tenant → Customer 360 → Catálogo → Simulação → Proposta → Documentos → Digitação → Mesa → Pipeline está estruturalmente conectado. O E2E com dados reais ainda não pode ser executado porque o tenant não possui configuração comercial/operacional.

## Fonte comercial recebida
Recebida e analisada `GOVERNO DO ACRE (2).xlsx`, versão 114, atualização 12/06/2026. Evidência normalizada em `data/source-evidence/gov-acre-v114.json` e documentada em `docs/imports/GOV-ACRE-V114.md`. A fonte comprova Governo do Acre, códigos/taxas/prazos/comissões e regras de Portabilidade+Refin, mas não identifica banco, provider/master, coeficiente nem checklist documental.

## Human Gate atual
Para importar/publicar a primeira rota real `761111 - GOV ACRE 1 DIG - AOL`, falta somente a identificação autoritativa de **banco** e **provider/master** da planilha. A própria fonte foi varrida e não contém esses campos. Coeficiente pode permanecer null/manual_pending inicialmente; checklist e stages podem ser configurados depois, mas não devem ser inventados como se viessem desta planilha.

## Próximo passo
Assim que os dados forem fornecidos/importados, criar configuração por fluxo seguro, executar E2E real, validar RLS/RBAC/state machines/documentos e continuar para os próximos módulos.
