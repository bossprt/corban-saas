# Cobrança da mensalidade (Pix) — design

Data: 02/11/2026. Dono: o dono da plataforma. Primeira empresa cobrada: MAIS VALOR.

## Intenção

A MAIS VALOR começou a usar o Corban e paga R$ 399,90 por mês. O dono quer cobrar pelo próprio sistema, com Pix, desde a
primeira mensalidade (vence 03/11/2026), sem custo de intermediário e com o mínimo de passos para ele e para a cliente.
Quem não paga perde o acesso depois da carência; quando o dono confirma o pagamento, o acesso volta na hora.

## Decidido pelo dono

- Valor: R$ 399,90 por mês. Vencimento todo dia 3, primeiro em 03/11/2026.
- Carência: 5 dias corridos. Dias 4 a 8: aviso. Do dia 9 em diante sem pagamento: bloqueio.
- Bloqueio: todos os usuários da empresa (administrador, gerentes, vendedores, portal). Nenhum dado é apagado ou alterado.
- Pix estático (QR Code e copia e cola) gerado pelo Corban, com valor e identificador. Sem intermediário por enquanto.
- O dono confirma o recebimento manualmente no /platform ("Recebido").
- Recebedor: chave Pix CPF do dono, nome abreviado a 25 caracteres (limite do Pix) e cidade, confirmados pelo dono em 02/11.
  Provisório: o dono vai trocar depois pela tela. Esses dados ficam só no banco de produção, nunca no código (repositório
  público).

## Objetivos

1. Cada empresa com assinatura tem uma cobrança por mês, criada sozinha a partir do dia de vencimento.
2. O administrador da empresa vê a cobrança do mês: valor, vencimento, situação, QR Code e Pix copia e cola.
3. Aviso vermelho em todas as telas da empresa para o administrador durante a carência.
4. Bloqueio depois da carência: toda tela e toda ação da empresa redirecionam para a tela "Mensalidade".
5. O dono vê todas as cobranças no /platform e marca "Recebido" (com a data); um engano se corrige com "Estornar" (motivo
   obrigatório), que fica registrado. Nada se apaga.

## Fora do escopo (agora)

- Confirmação automática (Asaas, Mercado Pago, Pix dinâmico com webhook). O modelo deve permitir ligar isso depois sem
  refazer: o pagamento é um evento com origem (`manual` agora).
- Recibo/nota fiscal em PDF, juros e multa, desconto, planos diferentes, autoatendimento, outras empresas (o modelo já
  serve para qualquer empresa, mas só a MAIS VALOR é cadastrada).

## Anti-objetivos

- Bloquear a empresa por erro do sistema (falha ao consultar a cobrança nunca bloqueia; o bloqueio só acontece quando a
  consulta responde que está bloqueada).
- Valor em ponto flutuante; histórico de pagamento editável ou apagável.
- Chave Pix, nome ou CPF no código, em migration, em log ou em URL.
- Enfraquecer RLS das tabelas existentes.

## Desenho

### Dados (uma migration versionada, `billing_v1`)

- `platform_billing_settings` (uma linha): `pix_key`, `pix_key_type` ('cpf','cnpj','email','phone','random'),
  `merchant_name` (até 25), `merchant_city` (até 15), `updated_at`, `updated_by`. RLS ligada, sem política para
  `authenticated`: só o servidor (service role) e funções `security definer` leem.
- `organization_subscriptions`: `organization_id` (único), `amount numeric(14,2)` > 0, `due_day smallint` 1..28,
  `grace_days smallint` 0..30, `starts_on date` (mês da primeira cobrança), `is_active`, auditoria. RLS ligada, sem
  política para `authenticated`.
- `organization_charges`: `organization_id`, `period date` (dia 1 do mês), `amount numeric(14,2)`, `due_on date`,
  `txid text` (ex.: `MAISVALOR202611`, só letras e números, até 25), `created_at`. Único (`organization_id`,`period`).
  Valor e vencimento copiados da assinatura no momento da criação (mudar a assinatura não muda cobrança já criada).
  Trigger impede `update` e `delete`.
- `organization_charge_events`: `charge_id`, `kind` ('paid','reversal'), `paid_on date` (para 'paid'), `note`
  (obrigatória em 'reversal'), `source` ('manual'), `actor_user_id`, `created_at`. Só `insert`; trigger impede
  `update`/`delete`. Um 'reversal' só entra se o último evento da cobrança for 'paid'; um 'paid' só se não estiver paga.
- Situação de uma cobrança (derivada, nunca gravada): paga se o último evento é 'paid'; senão em aberto (hoje ≤
  vencimento), vencida (até vencimento + carência) ou bloqueante (depois disso).

### Criação das cobranças (sem agendador)

O projeto não tem pg_cron. A função `ensure_organization_charges(p_org)` (security definer) cria, de forma idempotente
(`on conflict do nothing`), a cobrança de cada mês desde `starts_on` até o mês atual cujo vencimento já chegou (hoje ≥
dia do vencimento). Ela roda dentro das consultas abaixo, então a cobrança "aparece" no dia 3 na primeira vez que alguém
abre o sistema. Datas no fuso America/Sao_Paulo, como o resto do sistema (decisão do construtor).

### Consultas

- `billing_status(p_org)` → `{ blocked boolean, notice text|null, charge_id, due_on, amount }` para qualquer membro ativo
  da empresa (chama `ensure` antes). `blocked` = existe cobrança não paga com hoje > vencimento + carência.
- `my_billing(p_org)` → cobranças da empresa com situação, para o administrador (`role = 'admin'`) da empresa; os dados
  do recebedor necessários ao Pix (chave, nome, cidade) só saem por aqui e só para o admin.
- /platform usa o service role (como o resto da página) e grava pagamento/estorno por funções que conferem
  `platform_administrators`, mais o registro em `platform_admin_audit_events`.

### Pix (código no servidor)

- `src/lib/pix.ts`: monta o BR Code estático (EMV: 00, 26 com GUI `br.gov.bcb.pix` e chave, 52 `0000`, 53 `986`, 54
  valor com 2 casas a partir de string/centavos, 58 `BR`, 59 nome, 60 cidade, 62/05 txid, 63 CRC16-CCITT). Nome e cidade
  sem acento, em maiúsculas, cortados no limite. Testes unitários com um código de referência conhecido e o CRC.
- O QR é gerado no servidor com a biblioteca `qrcode` (já instalada) como imagem embutida. Botão "Copiar código".

### Telas

- **/app/mensalidade** (nova): administrador vê a cobrança em aberto (QR, copia e cola, valor, vencimento) e o histórico;
  outros perfis veem só "Mensalidade em aberto, procure o administrador da empresa" quando bloqueado.
- **Aviso**: faixa vermelha no topo do layout do app, só para o administrador, do vencimento até o pagamento
  ("Mensalidade de nov/2026 vencida há 2 dias. Pague até 08/11 para não bloquear." com link para /app/mensalidade).
- **Bloqueio**: `requireAppContext` consulta `billing_status` junto com as outras consultas; se `blocked` e a chamada não
  for da própria tela de mensalidade (opção `allowBillingBlocked`, como `allowPendingTerms`), redireciona para
  /app/mensalidade. Como toda página e toda server action passam por `requireAppContext`, ações também param. Falha na
  consulta = não bloqueia.
- **/platform → Cobrança** (nova seção): recebedor Pix (chave, tipo, nome, cidade); assinatura por empresa (valor, dia,
  carência, início, ativa); lista de cobranças de todas as empresas com situação e botões "Recebido" (data, padrão hoje)
  e "Estornar" (motivo).

### Decisões do construtor (revisão de 02/11)

- **API externa** (`/api/v1/*`, chave de API): também bloqueada (HTTP 402, código `billing_blocked`), coerente com
  "bloqueia todos". Falha na consulta não bloqueia.
- **Assinatura desligada** (`is_active = false`): não cria cobranças novas e não bloqueia; as cobranças já criadas
  continuam na lista como estão.
- **Entrega atrasada**: a carência conta do vencimento (decisão do dono). A entrega é planejada para antes de 08/11;
  se passar disso, o dono decide antes de ativar a assinatura.
- **Dono da plataforma**: o bloqueio vale para quem entra como membro da empresa; o dono confere a cobrança pelo
  /platform, não precisa entrar na MAIS VALOR.

### Limite conhecido do bloqueio

O bloqueio é do aplicativo (páginas e ações do servidor), não do banco: as políticas RLS existentes não mudam. Alguém da
empresa que chamasse a API do banco diretamente com o próprio login continuaria vendo os próprios dados. Aceito para o
piloto (o objetivo é cobrança, não segurança); bloquear no banco exigiria mexer em todas as políticas.

## Implantação

1. PR com migration, código, testes, CURRENT-TASK e CHANGELOG.
2. Human Gate: aplicar a migration em produção.
3. Human Gate: gravar o recebedor (dados que o dono confirmou em 02/11) e a assinatura da MAIS VALOR (R$ 399,90, dia 3,
   carência 5, início 11/2026) direto no banco de produção, fora do repositório, ou o dono digita na tela.
4. Conferir na tela da MAIS VALOR (com autorização) que a cobrança de nov/2026 aparece no dia 03/11.

## Deixado para o construtor

Nomes exatos de colunas e funções, layout fino das telas (mockup antes), texto das mensagens, testes.
