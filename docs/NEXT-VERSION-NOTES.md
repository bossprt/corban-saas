# Next.js 16.3.4 — Breaking Changes & Migration Guide

**Versão:** 16.3.4
**Data:** 2026-09-12
**Escopo:** Atualização do Next.js 16.3.4

## Resumo

Este documento registra as principais breaking changes entre Next.js 15 e a versão 16.3.4, com base na documentação local em `node_modules/next/dist/docs/`.

## Breaking Changes Principais

### 1. Turbopack por padrão

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/version-16.md`

**Mudança:**
- `next dev` e `next build` usam Turbopack automaticamente (a flag `--turbopack` não é mais necessária)
- Scripts em `package.json` devem remover a flag `--turbopack`

**Impacto:** Scripts antigos com `--turbopack` continuam funcionando, mas a flag é redundante.

---

### 2. Request APIs totalmente assíncronas

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/version-16.md`

**Mudanças:**
- `cookies()`, `headers()`, `draftMode()` → **apenas assíncronas** (`await cookies()`)
- `params` em layouts, páginas, `route.js`, `opengraph-image.js`, `twitter-image.js`, `icon.js`, `apple-icon.js` → agora é `Promise` (`await params`)
- `searchParams` em `page.js` → agora é `Promise` (`await searchParams`)
- **Remoção total de compatibilidade síncrona**

**Impacto:** Código que acessava `params` ou `searchParams` de forma síncrona vai quebrar.

---

### 3. Async `id` para icon/opengraph image e sitemap

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/version-16.md`

**Mudanças:**
- `id` passado para funções de geração de icon/opengraph image → `Promise<string>` (`await id`)
- `id` passado para função de geração de sitemap → `Promise<string>` (`await id`)

---

### 4. React Compiler promovido a estável

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/version-16.md`

**Mudança:**
- `experimental.reactCompiler` → `reactCompiler` (ainda não habilitado por padrão)

---

### 5. Remoção de `experimental_ppr`

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/codemods.md`

**Codemod:** `remove-experimental-ppr`

**Mudança:** `export const experimental_ppr = true` → remover completamente

---

### 6. Remoção de prefixo `unstable_`

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/codemods.md`

**Codemod:** `remove-unstable-prefix`

**Mudança:** `unstable_cacheTag`, `unstable_cache` → `cacheTag`, `cache`

---

### 7. Migração de middleware para proxy

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/codemods.md`

**Codemod:** `middleware-to-proxy`

**Mudanças:**
- `middleware.ts` / `middleware.js` → `proxy.ts` / `proxy.js`
- Export `middleware` → `proxy`
- `experimental.middlewarePrefetch` → `experimental.proxyPrefetch`
- `experimental.middlewareClientMaxBodySize` → `experimental.proxyClientMaxBodySize`
- `experimental.externalMiddlewareRewritesResolve` → `experimental.externalProxyRewritesResolve`
- `skipMiddlewareUrlNormalize` → `skipProxyUrlNormalize`

---

### 8. Migração de `next lint` para ESLint CLI

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/codemods.md`

**Codemod:** `next-lint-to-eslint-cli`

**Mudança:** `next lint` → `eslint`

---

### 9. Adoção de Cache Components

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/migrating-to-cache-components.md`

**Mudanças:**
- Config `dynamic`, `revalidate`, `fetchCache` → `use cache`, `cacheLife`
- `export const instant = false` para rotas que bloqueiam navegação
- `cacheComponents: true` em `next.config.ts`

---

### 10. Remoção de `prefetch = 'partial'`

**Fonte:** `node_modules/next/dist/docs/01-app/02-guides/upgrading/codemods.md`

**Codemod:** `remove-partial-prefetch`

**Mudança:** Remover `export const prefetch = 'partial'` após habilitar `partialPrefetching` global

---

## Fluxo de Migração Recomendado

```bash
npx @next/codemod@canary upgrade latest
npx @next/codemod@canary remove-experimental-ppr .
npx @next/codemod@canary remove-unstable-prefix .
npx @next/codemod@canary middleware-to-proxy .
npx @next/codemod@canary next-lint-to-eslint-cli .
npx @next/codemod@canary cache-components-instant-false ./app
npx @next/codemod@canary remove-partial-prefetch ./app
npx @next/codemod@canary next-async-request-api .
npx next typegen