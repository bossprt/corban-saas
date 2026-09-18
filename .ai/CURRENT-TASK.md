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

## Bloqueio comprovado de dados
Live DB: 0 bancos, 0 tabelas, 0 checklists, 0 stages, 0 simulations, 0 proposals. O sistema não deve inventar banco, convênio, taxa, coeficiente, comissão, tabela ou checklist comercial.

## Human Gate atual
Para validar o Vertical Slice ponta a ponta com dados reais é necessária uma fonte de configuração comercial válida do usuário/empresa: ao menos banco, provedor/master, convênio, produto/modalidade, tabela/versão com taxa/coefficient/termos, checklist documental e definição de SLA/stages desejados. Sem isso, qualquer seed seria dado comercial inventado.

## Próximo passo
Assim que os dados forem fornecidos/importados, criar configuração por fluxo seguro, executar E2E real, validar RLS/RBAC/state machines/documentos e continuar para os próximos módulos.
