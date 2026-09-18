# CURRENT TASK — CORBAN OS V2

**Atualização:** 17/09/2026  
**Branch:** `architecture/corban-os-master-v2`

## Foco

Concluir a transição documental V1 → V2 e iniciar a fundação executável da primeira fatia vertical.

## Concluído nesta branch

- [x] Criada branch isolada V2.
- [x] Criado `CORBAN-OS-PROJECT-CONTEXT-V2.md`.
- [x] Consolidado `CORBAN-OS-MASTER-V2.md`.
- [x] Confirmado que a documentação antiga de estado está desatualizada e não pode ser usada como prova do estado atual.
- [x] Confirmado no `package.json` da branch que Drizzle, Zod, Vitest e Playwright ainda não estão instalados.
- [x] Definida primeira fatia: Login/Tenant → Customer 360 → Bank/Product/Table → Simulation → Proposal → Documents → Digitization → Pipeline.

## Próxima execução

1. Atualizar contexto dos agentes para apontar primeiro ao MASTER V2.
2. Fazer inventário factual de schema/migrations atuais e reconciliar com o Supabase já endurecido.
3. Definir schema mínimo V0 da fatia vertical e migrations versionadas.
4. Implementar tenant/auth/membership fail-closed.
5. Criar testes de isolamento antes de expandir módulos.
6. Seguir verticalmente até Customer 360 e primeira Proposal.

## Gates

Não alterar `main` diretamente. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Qualquer operação irreversível/externa relevante exige Human Gate.

## Regra de retomada

Nova IA deve ler, nesta ordem:
1. `CORBAN-OS-PROJECT-CONTEXT-V2.md`
2. `CORBAN-OS-MASTER-V2.md`
3. `CORBAN-CURRENT-STATE.md` (como histórico factual a ser reconciliado)
4. `.ai/RULES.md`
5. `.ai/DECISIONS.md`
6. este arquivo
7. código, migrations e Git reais antes de agir.
