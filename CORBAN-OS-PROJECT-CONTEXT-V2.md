# CORBAN OS — PROJECT CONTEXT V2

Status: contexto persistente de retomada.
Branch de arquitetura: architecture/corban-os-master-v2.
Regra: o projeto deve ser retomável por qualquer agente de IA lendo o repositório, sem depender do histórico de chats.

## Missão
Corban OS é um SaaS multi-tenant e white-label para operação de correspondentes bancários. Deve cobrir o ciclo de cliente, oportunidade, simulação, proposta, documentos, digitação, esteira, produção, contratos, comissão, conciliação, repasses, metas, financeiro, gestão, integrações e auditoria.

## Ecossistema
- Corban OS: fonte de verdade da operação de correspondente bancário.
- Growth OS: aquisição, campanhas, experimentos, tracking e atribuição.
- SmartMatch: motor especializado de conversão/atendimento/recuperação.
- Cérebro/Control Tower: coordenação de projetos, agentes e execução.

Os produtos não devem ser fundidos. Integram-se por contratos versionados, APIs e/ou eventos.

## Regras arquiteturais essenciais
- multi-tenant fail-closed e isolamento testado;
- tenant e brand são conceitos distintos;
- dinheiro sem Float e histórico financeiro imutável;
- regras, tabelas, comissões e overrides versionados e auditáveis;
- IA sugere/interpreta; validação financeira crítica é determinística e usa Human Gates quando ambígua;
- arquivos externos originais, hashes e status brutos são preservados;
- proposta/contrato preserva snapshots históricos de dados bancários, PIX, documentos e tabela utilizada;
- sync operacional da proposta termina em estado terminal (pago ao cliente ou encerrado/cancelado); ciclo financeiro pode continuar;
- comissão diferida futura é projeção, não receita recebida;
- consumo de serviços externos específicos do tenant (ex.: enriquecimento, mensageria, telefonia, assinatura) é contratado/bancado pelo próprio tenant por padrão;
- dependências externas estratégicas ficam atrás de interfaces próprias.

## Primeira fatia funcional
Login/Tenant -> Customer 360 -> Banco/Produto/Tabela -> Simulação -> Proposta -> Documentos -> Enviar para Digitação -> Mesa Operacional -> Esteira.

A arquitetura deve deixar contratos preparados para produção/sync, comissão, conciliação, diferido, metas, repasses e BI sem exigir que todos estejam completos antes da primeira entrega.

## Regra de independência de chat
Antes de executar:
1. ler este arquivo;
2. ler CORBAN-CURRENT-STATE.md, .ai/MASTER-CONTEXT.md, .ai/DECISIONS.md e .ai/CURRENT-TASK.md;
3. conferir código, migrations, banco e Git reais;
4. nunca assumir que documentação antiga representa estado implementado;
5. registrar decisões relevantes e atualizar estado de retomada.

## Documentação alvo V2
O MASTER V2 deve consolidar a visão completa e substituir contradições conceituais antigas sem apagar evidências históricas. A documentação operacional deve manter MASTER, CURRENT STATE, DECISIONS, CURRENT TASK e CHANGELOG coerentes.

## Regra de velocidade
Construir em fatias verticais completas e testáveis. Reutilizar componentes maduros quando reduzirem tempo/risco, mas nenhum terceiro vira fonte de verdade dos domínios centrais do Corban OS.
