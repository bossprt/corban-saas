# CORBAN OS — NEXT WAVE PLAN V3

**Data:** 2026-09-20  
**Branch:** `architecture/corban-os-master-v2`  
**Status:** preparado para execução pelo Claude.  
**Regra:** sem `main`; sem DDL LIVE, secrets, gasto ou ação irreversível sem Human Gate explícito.

## Objetivo

Avançar o Corban OS após o Commercial Model V3 LIVE, priorizando experiência real do tenant, robustez de importação e fundação dos agentes de IA sem introduzir lock-in ou custo não autorizado.

## Ordem de execução

### Wave A — UX real do tenant + CEP
1. Revisar visualmente e funcionalmente `/app/comercial` como tenant Smart.
2. Garantir que o fluxo seja entendido sem conhecimento técnico:
   - Banco/Instituição
   - Convênio
   - Produto/Tabela
   - Tipo de Contrato
   - Prazo
   - comissão recebida
   - política/grupos de repasse
   - Origem da Produção: Própria/Terceiro.
3. Corrigir textos, ordem, estados vazios, feedback, loading, permissões e erros.
4. Implementar CEP automático no cadastro/edição de cliente:
   - aceitar com/sem máscara;
   - normalizar para 8 dígitos;
   - preencher logradouro, bairro, cidade, UF;
   - permitir edição manual;
   - número/complemento continuam manuais;
   - não bloquear cadastro se lookup falhar;
   - não sobrescrever silenciosamente endereço já alterado pelo usuário;
   - preferir fonte gratuita/sem chave na primeira versão.
5. Criar testes unitários e de Server Action/route conforme arquitetura encontrada.

### Wave B — Importação comercial atômica
Problema atual: valida o arquivo inteiro, mas grava linha a linha.

Implementar:
- RPC bulk transacional tenant-scoped para condições comerciais;
- all-or-nothing no momento da persistência;
- idempotência por versão + tipo de contrato + prazo;
- resposta por linha com status/erro;
- nenhum Float;
- RLS/tenant fail-closed;
- rollback-only SQL harness adversarial;
- preservar preview atual;
- reprocessamento seguro.

Nenhuma DDL LIVE sem Human Gate.

### Wave C — Fundação do Agente de Importação IA
A IA não substitui parser nem regras financeiras.

Arquitetura:
```text
arquivo
→ parser determinístico
→ fingerprint
→ estrutura/headers/amostra
→ AI Import Mapper
→ mapping proposto + confidence + evidence
→ validadores determinísticos
→ preview humano
→ política de repasse
→ bulk import
```

Implementar sem secret real:
- interface provider-agnostic;
- Gemini como adapter/default preferencial inicial;
- provider mock/fake para testes;
- schema de request/response tipado;
- confidence por campo e global;
- unknown columns preservadas;
- nenhum campo financeiro inventado;
- decisão/mapeamento humano persistível/versionável;
- memória por origem/layout;
- fingerprint de arquivo/layout;
- reuso de mapping somente quando compatível;
- mudança relevante deve disparar nova revisão;
- fallback manual sempre disponível.

Não adicionar chave Gemini real. Parar no Human Gate de secret/gasto.

### Wave D — Metering / créditos de IA
Preparar modelo de consumo sem definir preço comercial final.

Entidades conceituais:
- ai_usage_jobs
- ai_usage_events
- ai_credit_ledger ou estrutura equivalente
- organization_ai_limits
- provider/model/capability
- input/output usage
- estimated_cost
- actual_cost
- credits_charged
- status
- source/import/job references

Regras:
- NUMERIC/integer scaled;
- append-only para ledger;
- tenant isolation;
- idempotency por job;
- teto mensal configurável;
- nenhuma chamada paga sem saldo/regra válida;
- custo do provedor separado do preço cobrado;
- usuário final vê créditos, não tokens.

Preparar migration + harness. NÃO aplicar LIVE sem Human Gate.

### Wave E — Agente Operacional / Action Center
Começar deterministic-first para manter custo baixo.

Sinais iniciais:
- proposta acima do SLA;
- lead sem contato/follow-up;
- documento obrigatório pendente;
- comissão esperada sem recebimento;
- divergência financeira;
- tabela vencendo/vencida;
- integração/job falhando repetidamente;
- fila sem responsável;
- item parado sem movimentação;
- backlog anormal.

Modelo:
```text
eventos/métricas
→ regras determinísticas
→ operational_attention_items
→ prioridade
→ evidência
→ recomendação
→ AI summary opcional
→ ação permitida
```

Action Center deve exibir:
- Crítico / Alto / Médio / Baixo;
- motivo;
- evidência;
- impacto;
- responsável;
- próxima ação sugerida;
- resolver / ignorar / adiar;
- histórico.

Autonomia:
1. observar;
2. recomendar;
3. executar apenas ações reversíveis autorizadas;
4. Human Gate para finanças, comissão, publicação, exclusão e ações irreversíveis.

Não usar IA para inferir desempenho subjetivo de funcionário. Ociosidade deve vir de eventos e SLAs objetivos.

### Wave F — Payout real e snapshot de proposta
Ligar Commercial Model V3 ao financeiro existente sem confundir:
- comissão recebida;
- política de repasse;
- grupo/vendedor aplicado;
- gerente/supervisor;
- valor efetivo;
- pagamento realizado.

A proposta deve congelar snapshot da condição e da regra aplicada. Mudança futura de política não altera histórico.

Antes de implementação:
- auditar `proposal_commercial_snapshots`, `network_split_rule_versions`, `commission_rule_components`, financial ledger e reconciliation;
- propor integração mínima sem duplicar motores já existentes;
- preservar expected/reported/received/downstream_paid como fatos distintos.

## Definition of Done da próxima wave

- tenant consegue configurar e entender o V3 no navegador;
- CEP automático funcional e resiliente;
- importação comercial com persistência atômica;
- camada de agente IA pronta para receber Gemini sem secret hardcoded;
- metering desenhado/testado, sem cobrança real ainda;
- Action Center mínimo deterministic-first;
- integração de payout desenhada antes de tocar histórico financeiro;
- testes unit/tsc/eslint/build verdes;
- SQL rollback-only/adversarial verde para toda DDL preparada;
- docs e handoff atualizados;
- commits/push apenas na branch V3;
- parar em todo Human Gate real.

## Human Gates esperados

1. aplicar migration de bulk import, se DDL;
2. aplicar migration de metering/Action Center, se DDL;
3. cadastrar secret/API key Gemini;
4. autorizar primeiro gasto/chamada paga;
5. qualquer DDL financeiro/payout LIVE;
6. qualquer alteração irreversível em produção.

## Regra de documentação

Toda decisão nova deve ser registrada em:
- `docs/CORBAN-COMMERCIAL-MODEL-V3.md` quando for requisito de produto;
- `.ai/CURRENT-TASK.md` para retomada operacional;
- `CORBAN-CURRENT-STATE.md` quando virar estado verificado;
- ADR quando alterar arquitetura/invariante.

Nunca depender apenas do histórico do chat.
