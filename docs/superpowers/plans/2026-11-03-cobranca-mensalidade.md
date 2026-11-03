# Cobrança da mensalidade (Pix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Mensalidade mensal por Pix estático, aviso na carência, bloqueio depois, confirmação manual pelo dono.

**Architecture:** Migration `billing_v1` (tabelas fechadas + funções security definer, cobranças criadas sob demanda,
eventos imutáveis). `src/lib/pix.ts` monta o BR Code. `requireAppContext` redireciona empresas bloqueadas para
/app/mensalidade; as rotas /api/v1 recusam com 402. /platform ganha a seção Cobrança.

**Tech Stack:** Next 16, Supabase Postgres, node:test, `qrcode`.

**Spec:** `docs/superpowers/specs/2026-11-02-cobranca-mais-valor-design.md`

## Global Constraints

- Dinheiro `numeric(14,2)`; no TS só string/centavos (`bigint`), nunca float.
- Chave, nome e cidade do Pix nunca no código, migration, log ou URL.
- Cobranças e eventos imutáveis (trigger); correção só por evento `reversal` com motivo.
- Falha ao consultar a cobrança nunca bloqueia.
- Datas em America/Sao_Paulo. Bloqueado quando hoje > vencimento + carência e não paga, assinatura ativa.

## Review Focus

1. Admin de outra empresa chamando `my_billing`/`billing_status` com p_org alheio → `not_authorized` (testar no SQL).
2. Valor com centavos ("399,90", "399.9") → BR Code campo 54 = `399.90`.
3. Nome/cidade com acento ou longos → sem acento, cortados (25/15).
4. Estornar cobrança não paga, ou marcar paga duas vezes → recusado.
5. Assinatura desligada com cobrança aberta → não bloqueia.

---

### Task 1: Migration billing_v1

**Files:** Create `supabase/migrations/<versão>_billing_v1.sql`, `tests/security/billing-contract.sql`.

- Tabelas: `platform_billing_settings` (id boolean pk default true check id), `organization_subscriptions`,
  `organization_charges`, `organization_charge_events` conforme o spec. RLS ligada, sem políticas, revoke de anon/authenticated.
- `private.ensure_organization_charges(p_org uuid)`; `private.charge_state(charge, today)` → 'paid'|'open'|'overdue'|'blocking'.
- `public.billing_status(p_org) returns jsonb` (membro ativo) → `{blocked, overdue, period, due_on, block_on, amount}`.
- `public.my_billing(p_org) returns jsonb` (role admin) → `{receiver:{key,name,city}|null, charges:[{id,period,amount,due_on,txid,state,paid_on}]}`.
- `public.api_billing_blocked(p_key text) returns boolean` (service_role).
- `public.platform_set_billing_settings`, `platform_set_subscription`, `platform_mark_charge_paid(p_charge, p_paid_on)`,
  `platform_reverse_charge(p_charge, p_note)`: só service_role; conferem regras; o servidor já conferiu o dono da plataforma.
- Verificar: aplicar no Postgres local (`supabase db reset` ou `psql -f`) e rodar o contrato SQL.

### Task 2: BR Code Pix

**Files:** Create `src/lib/pix.ts`, `tests/unit/pix.test.ts`; Modify `tests/unit/tsconfig.json` (include `src/lib/pix.ts`).

- `pixPayload({key, name, city, amount, txid}: {key:string;name:string;city:string;amount:string;txid:string}): string`
- `crc16(s: string): string` (CCITT-FALSE, 4 hex maiúsculos).
- Testes: `crc16('123456789') === '29B1'`; payload contém `5406399.90`, `5802BR`, `62190515MAISVALOR202611`, termina com CRC
  válido do resto; nome "José Ação" → `JOSE ACAO`; nome 26 letras cortado em 25.
- Run: `npm run test:unit`.

### Task 3: Bloqueio e tela da empresa

**Files:** Modify `src/lib/appContext.ts`, `src/app/app/layout.tsx`, `src/app/api/v1/leads/route.ts`, `src/app/api/v1/contracts/route.ts`;
Create `src/app/app/mensalidade/page.tsx`, `src/app/app/mensalidade/CopyPix.tsx`.

- `requireAppContext({allowBillingBlocked?: boolean})`; contexto ganha `billing: {blocked:boolean; overdue:boolean; period?:string; block_on?:string} | null`.
- Layout: faixa vermelha para admin quando `billing.overdue`.
- Página: admin vê QR (`qrcode.toDataURL`) e copia e cola; outros perfis veem o aviso.
- API: antes do RPC, `api_billing_blocked(key)` true → `402 {error:'billing_blocked'}`.

### Task 4: /platform → Cobrança

**Files:** Modify `src/app/platform/page.tsx`, `src/app/platform/actions.ts`.

- Ações `saveBillingSettings`, `saveSubscription`, `markChargePaid`, `reverseCharge`; todas com `gate()` e
  `platform_admin_audit_events`.
- Verificar: build (`npm run build`), testes, tela local com Playwright e screenshot.

### Task 5: Docs e PR

- `.ai/CURRENT-TASK.md`, `.ai/CHANGELOG.md`; commit; PR. Human Gates: migration em produção; dados do recebedor e assinatura.
