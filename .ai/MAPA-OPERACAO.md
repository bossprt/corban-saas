# MAPA REAL DA OPERAÇÃO — CORBAN SaaS

**Versão:** v2 aprovada pelo dono em 24/09/2026
**Fonte:** entrevista com o dono (especialista de domínio). Este documento substitui como verdade de produto os documentos CORBAN-OS-* e a memória-mestre produzidos anteriormente, que passam a ser apenas hipóteses a conferir contra código e banco.

## 0. Princípios

- O Corban funciona sozinho. Nenhuma função depende do DeskcommCRM; a integração é opcional e ligada em Configurações.
- Nenhum percentual, regra ou política é fixo no código: tudo é configurável pelo dono de cada empresa, versionado e congelado no momento da venda.
- Dinheiro sempre em aritmética exata; histórico financeiro imutável, correção só por lançamento compensatório.
- IA sugere; valor financeiro só vira oficial após cálculo determinístico e aprovação humana.
- Cada fase termina com uso real, provado na tela. Toda mudança de banco sai como migration versionada.

## 1. Quem vende

- Qualquer usuário interno pode vender: vendedor, atendente de call center, operador, supervisor, gerente, admin.
- Externos também originam propostas: corretores, parceiros, balcão, afiliados, promotoras (ex.: Smart Promotora). Cada um tem comissão cadastrada.
- Corretores e parceiros acessam um portal próprio: veem suas propostas, esteira, extrato/saldo, pedem saque e enviam propostas, que entram como "aguardando validação" até o time interno validar.

## 2. Entrada de cliente e proposta

- Três portas com igual importância: cadastro manual, lead via API (DeskcommCRM ou qualquer outra fonte), proposta enviada pelo portal do corretor.
- Cliente é único por CPF e telefone. Se chega de novo com dado diferente, o sistema guarda os dois: o novo vira principal, o antigo fica no histórico (vários telefones, endereços, contas).
- Todo registro guarda sua origem.
- Um cliente tem quantos contratos precisar (bancos, produtos e épocas diferentes, inclusive legados). Refinanciamento e portabilidade não são ligados ao contrato anterior: basta aparecerem no histórico do cliente. Buscar por CPF mostra todos os contratos que o cliente já teve na empresa.

## 3. Produtos e simulação

- O sistema atende todos os produtos (INSS, consignado público, CLT/privado, FGTS, cartão, refinanciamento, portabilidade etc.). Modelo genérico: tipo de operação + convênio + banco + tabela.
- Simulação pode acontecer em qualquer lugar: fatores do Corban, planilha, portal do banco, CRMs de terceiros (Promobank, Promosys etc.). O Corban não exige simulação interna para registrar a proposta.

## 4. Proposta, digitação e esteira

- A proposta entra de três formas: antes da digitação (fila para digitador), depois da digitação (com número/ADE do banco), ou por importação de relatório.
- Deduplicação de proposta por banco + ADE.
- Status atualizado de três formas: manual, relatório importado, API do banco ou de CRM que a promotora cede. Um adaptador por fonte.
- Alertas configuráveis: proposta parada há X dias; pendência vencendo; contrato pago sem comissão após X dias; parcela diferida atrasada.
- Metas por vendedor e equipe, configuráveis pelo dono.

## 5. Recebimento da comissão

- Chegam dois relatórios separados por fonte pagadora:
  - **À vista:** lista de contratos pagos, % e valor; total do relatório = soma das linhas.
  - **Diferido:** regra própria. Exemplo: contrato de R$ 10.000,00 com 6% à vista (R$ 600,00) e 14% diferido (R$ 1.400,00) dividido pelo número de parcelas do contrato do cliente (120 → cerca de R$ 11,67/mês). Cada parcela é arredondada e o resíduo é ajustado na última, para o total fechar exato.
- Conciliação contrato a contrato contra o esperado.
- Estorno do banco (cancelamento, quitação, portabilidade) é registrado e gera débito.

## 6. Imposto

- Alíquota depende do regime tributário de cada empresa (configurável).
- Isenção é atributo da fonte pagadora: certos bancos/promotoras pagam comissão que já chega isenta.

## 7. Cascata de distribuição

```
comissão recebida
(-) imposto, se a fonte pagadora não for isenta
(-) lucro da empresa (% definido pelo dono)
= valor a distribuir
    gerente (opcional)
    supervisor (opcional)
    originador / responsável do contrato
```

- Rateio entre gerente, supervisor e originador é opcional e em qualquer combinação, decidido pelo dono.
- Percentuais saem de um motor de regras com precedência: global < banco/tabela < grupo de comissão < vendedor < exceção. Regras versionadas e congeladas na proposta.
- Hierarquia do rateio vem da equipe do vendedor e/ou da filial, congelada na data da venda; para corretores/parceiros pode ser diferente. Configurável.
- O dono decide por regra se o diferido também é repassado à rede.

## 8. Repasse e conta corrente do vendedor

- Repasse só é liberado depois que a empresa recebe do banco e concilia.
- Dois modelos, o dono escolhe:
  - **Fechamento periódico** (diário, semanal, quinzenal, mensal ou outro), com extrato.
  - **Conta interna:** contratos conciliados creditam o saldo; o vendedor pede saque do valor que quiser.
- Conta corrente do vendedor (razão imutável de débito/crédito): comissão conciliada, estorno, adiantamento/vale (à vista ou parcelado), bônus/premiação, descontos/custos (consultas, material, multa), ajuste manual com justificativa e aprovação.
- Estorno desconta proporcionalmente de todos que receberam daquele contrato (originador, supervisor, gerente).
- Saldo negativo: política escolhida pelo dono (carregar, limite de % por repasse, cobrança separada).
- Saída do dinheiro evolui: marcar pago manualmente → arquivo em lote (CNAB/PIX) → PIX por API. Sempre com aprovação humana.

## 9. Financeiro da empresa

- Financeiro completo: contas a pagar e a receber, plano de contas, centro de custo, fluxo de caixa, DRE.
- Conciliação bancária: marcação manual sempre disponível; importação de OFX/CSV opcional.
- Integração opcional com ERP (ex.: Omie, Conta Azul) a avaliar.

## 10. Integrações e API

- **API pública desde cedo:** REST versionada (`/api/v1`), chave por empresa com escopos, documentação OpenAPI, webhooks de saída assinados (proposta mudou, contrato pago, estorno, repasse). O DeskcommCRM é apenas um cliente dessa API.
- **Hub de conectores**, cada um ligado em Configurações com credencial da empresa:
  - Consulta de dados: LEMIT (enriquecimento de CPF).
  - Margem consignável e contratos ativos: provedores a pesquisar.
  - Esteira: APIs de bancos e promotoras.
  - Comunicação: SMS e URA ativa.
  - Endereço: Correios/CEP.
  - Porta aberta para conectores futuros.
- APIs pagas usam credencial do próprio cliente; gratuitas vêm embutidas.
- Toda consulta de dado pessoal registra quem consultou, qual CPF e a finalidade.
- Retorno ao DeskcommCRM (quando ligado): proposta enviada, contrato pago, perdido.

## 11. Campanhas

- SMS e URA ativa sobre listas filtradas de clientes para prospecção.
- Obrigatório respeitar a lista Não Me Perturbe (autorregulação ABBC/Febraban) e o opt-out do cliente.

## 12. IA

- Assistente em todas as etapas: lê relatórios, sugere conciliação, detecta divergência, cobra pendência, ajuda na busca.
- Nunca publica valor financeiro sem cálculo determinístico e aprovação humana.

## 13. Relatórios

- Produção; comissão e conciliação; repasse e extratos; financeiro.
- Formatos: tela com filtros (clicar abre a proposta), Excel/CSV, PDF com logo, envio agendado por e-mail/WhatsApp.

## 14. Permissões

- Papéis padrão (admin, gerente, supervisor, operador, vendedor, corretor externo, financeiro), editáveis, e o dono pode criar papéis marcando ver/criar/editar/aprovar por módulo.
- Visibilidade por hierarquia (próprio → equipe → filial → tudo) com exceções liberadas pelo dono. Aplicada no banco (RLS), não só na tela.
- Sem máscara de dados sensíveis; acesso a dado sensível fica registrado silenciosamente.

## 15. Assinatura (venda do Corban)

- Planos por porte com limites de usuários, módulos e integrações.
- Gateway automático (boleto/PIX/cartão recorrente), bloqueio após X dias de atraso.
- Teste grátis por autocadastro, com verificação de e-mail e proteção contra abuso.

## 16. Visual e dashboards

- Personalidade híbrida: dashboards de impacto para gestor e vendedor; telas de operação densas para o operador (tabelas fortes, atalhos, busca Ctrl+K).
- Tema claro por padrão, escuro opcional.
- Marca Corban própria + logo e cor de destaque de cada empresa. Identidade da marca em definição em outro projeto: tokens plugáveis.
- Vendedor usa muito no celular: telas dele são mobile-first.
- Base de código aberto: Radix Primitives, TanStack Table, cmdk, Recharts. Tipografia IBM Plex Sans + IBM Plex Mono, números tabulares.
- Dashboard do gestor: produção e receita (esperado × recebido × lucro líquido), rankings, dinheiro em risco, funil da esteira.
- Dashboard do vendedor: meta e produção, quanto vou ganhar (previsto/liberado/saldo), minhas pendências, oportunidades.
- Dashboards ligados a dados reais fase a fase; nenhum número falso em tela.

## 16a. Onboarding de base legada

- Corban que compra o sistema pode trazer clientes e contratos históricos do sistema antigo.
- Entram marcados como "legado", com sistema de origem e data de corte por empresa (início de uso do Corban).
- Somente consulta: aparecem na ficha do cliente e na busca; não entram em dashboards, metas, rankings, comissão, conciliação, repasse nem financeiro; não são editáveis.
- Usados no dedup por CPF: cliente legado que volta é reconhecido, nunca duplicado.
- Uso em oportunidades (refin/portabilidade) fica desligado por padrão; o dono liga se quiser.
- Importação por lote com prévia, relatório de erros e desfazer o lote inteiro, sobre o pipeline de importação existente.

## 17. Fases

| Fase | Entrega |
|---|---|
| F0 | Saneamento: trazer ao Git as 4 migrations que existem só em produção; ambiente de teste; testes de tela (Playwright). |
| F1 | Design system e casca do app; busca Ctrl+K; tela "Hoje"; papéis e visibilidade; chaves de módulo por plano. |
| F2 | Cliente único (dedup CPF/telefone, histórico de contatos, origem); cadastro manual; `POST /api/v1/leads`. |
| F3 | Proposta (antes/depois da digitação, dedup banco + ADE), esteira kanban, status manual e por relatório, pendências, alertas, metas. |
| F4 | Motor de regras de comissão: precedência, versões, imposto por regime e isenção por fonte, lucro, rateio, diferido. |
| F5 | Recebimento e conciliação: relatórios à vista e diferido, conciliação contrato a contrato, estorno, alertas financeiros. |
| F5.5 | Onboarding de base legada (clientes e contratos históricos, só consulta). |
| F6 | Repasse e conta corrente do vendedor: fechamento ou conta interna, avulsos, estorno proporcional, saldo negativo, pagamento manual. |
| F6.5 | Financeiro da empresa: contas a pagar/receber, plano de contas, centro de custo, fluxo de caixa, DRE, OFX. |
| F7 | Portal do corretor. |
| F8 | Hub de conectores (LEMIT, promotoras, DeskcommCRM), pagamento em lote CNAB/PIX. |
| F8.5 | Oportunidades: margem e contratos ativos. |
| F9 | Agentes de IA. |
| F10 | Campanhas SMS/URA com Não Me Perturbe. |
| F11 | Comercialização: planos, gateway, autocadastro com teste grátis. |
