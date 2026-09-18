# INTERNAL DIGITIZATION + OPERATIONAL PIPELINE V0

**Status:** preparado no Git; não aplicado.

Fluxo da primeira fatia:
Proposal documentalmente pronta → DigitizationJob → OperationalCase → OperationalStage → OperationalEvent.

A fila de digitação é separada da Proposal. Isso permite prioridade, atribuição, bloqueio, tentativas e referência externa sem transformar a proposta em uma fila de trabalho.

OperationalCase representa a posição atual. OperationalEvent preserva o histórico append-only. O status externo bruto é guardado separadamente do estado canônico, evitando que nomenclaturas de bancos/Masters contaminem a máquina interna.

OperationalStage permite visual configurável por tenant, mas cada etapa aponta para um estado técnico canônico. Assim a empresa pode chamar a coluna de “Mesa”, “Digitação”, “Banco” etc. sem quebrar automações.

Um índice parcial impede duas tarefas de digitação ativas para a mesma Proposal. FKs compostas impedem cruzamento de tenant. Eventos autenticados são SELECT/INSERT, sem UPDATE/DELETE.

Antes de produção ainda são necessários guards transacionais de domínio para: documentos obrigatórios validados/waived antes da fila; transições permitidas; coerência stage↔canonical_state; e autorização por papel/RBAC.
