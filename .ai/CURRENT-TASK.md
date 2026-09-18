# CURRENT TASK — CORBAN OS V2

**Atualização:** 18/09/2026  
**Branch:** `architecture/corban-os-master-v2`

## Estado atual consolidado
- Vertical Slice V0 database foundation aplicado live e validado.
- Domain Primitive `create_customer_with_timeline` aplicado live; Customer Server Action usa RPC atômica.
- App Shell, Dashboard, Customer 360, Catálogo, Propostas e Operação implementados na branch.
- Vercel conectado ao GitHub; Production permanece em `main`; branch V2 gera Preview automaticamente.
- Variáveis públicas do Supabase foram configuradas na Vercel para **All Environments**:
  - `NEXT_PUBLIC_SUPABASE_URL`
  - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- Deployments Preview anteriores falharam no prerender de `/login` porque o build não recebeu as variáveis públicas naquele momento.
- Next.js é 16.3.4. Entrada de routing migrada de `middleware.ts` para `proxy.ts` na branch V2.
- `main` permanece intocada.

## Segurança live
- Gate A/B tenant/auth/membership passou.
- Legacy RLS migrado para membership.
- Vertical Slice: RLS ativo nas tabelas verificadas.
- Security advisor final conhecido: 0 ERROR; WARN operacional de Leaked Password Protection Disabled; INFO intencionais nas platform tables service-role-only.
- Não expor `SUPABASE_SERVICE_ROLE_KEY` ao browser/Vercel público.

## Próxima execução
1. Disparar novo Preview após confirmação de env vars em All Environments.
2. Inspecionar build; corrigir autonomamente erros de TypeScript/Next/Tailwind/runtime na branch.
3. Quando Preview ficar Ready, validar `/login`, sessão, `/app` e membership fail-closed.
4. Continuar state-machine/RBAC/storage hardening sem publicar produção nem alterar main sem Human Gate.

## Gates
Não alterar `main`. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Operação irreversível, gasto, billing/money ou mudança externa relevante exige Human Gate.
