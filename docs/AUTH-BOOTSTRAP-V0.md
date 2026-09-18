# AUTH / FIRST ORGANIZATION BOOTSTRAP V0

**Status:** login real conectado; bootstrap administrativo ainda não executado.

## Diagnóstico corrigido
O repositório já possuía cliente SSR e middleware Supabase, porém a tela de login era apenas visual. O browser client usava `@supabase/supabase-js` diretamente enquanto o servidor usa `@supabase/ssr`, o que poderia deixar a sessão do browser fora do fluxo de cookies esperado pelo middleware.

## Implementado
- login com `signInWithPassword`;
- browser client migrado para `createBrowserClient`;
- entrada `/app` exige usuário autenticado e membership ativo;
- usuário autenticado sem membership vai para `/access-pending`;
- fail-closed: autenticação sozinha não concede tenant.

## Bootstrap seguro
Não haverá signup público que permita ao cliente escolher `organization_id`.

Fluxo planejado:
1. identidade é criada por fluxo administrativo/controlado;
2. backend privilegiado cria Organization;
3. backend privilegiado cria Membership `admin`;
4. usuário faz login normal;
5. RLS resolve acesso pela membership ativa.

A criação Organization + Membership precisa ser atômica e usar backend/service role protegido, nunca service role no browser.

## Gate A/B
Com duas identidades de teste autenticadas e duas organizations/memberships controladas, executar o harness A/B. As identidades podem ser removidas depois do teste, mas não devem ser fabricadas por INSERT direto em `auth.users`.
