# FIRST ADMIN BOOTSTRAP — RUNBOOK V0

**Objetivo:** resolver o primeiro administrador sem criar signup público e sem manter um bypass permanente.

## Princípio
O endpoint normal `POST /api/admin/organizations` exige um admin existente. Isso é correto depois do primeiro tenant, mas não pode criar o primeiro admin.

O primeiro bootstrap é uma **cerimônia operacional única**, executada somente por operador da plataforma com acesso administrativo ao Supabase. Não existe endpoint público `/bootstrap-first-admin`.

## Procedimento
1. Criar/convidar a primeira identidade pelo Supabase Auth Admin, em contexto servidor/administrativo.
2. Aplicar a migration `admin_org_bootstrap_v0`, se ainda não aplicada.
3. Executar `bootstrap_organization_admin(user_id, organization_name, document, plan)` com contexto service_role.
4. Confirmar exatamente 1 Organization ativa, 1 Membership admin ativa e 1 Profile compatível para o user_id.
5. Fazer login normal pela aplicação e confirmar `/app`.
6. A partir desse momento, novos tenants usam o endpoint administrativo normal.
7. Não criar token, flag ou rota de “primeiro acesso” que permaneça habilitada.

## Gate A/B
Para o teste de isolamento, criar duas identidades controladas via Auth Admin e usar o mesmo primitive service-role-only para duas organizações de teste. Executar o harness A/B e, ao final, remover somente os dados artificiais de teste em procedimento explícito e auditado.

## Por que não automatizar agora
O projeto principal está vazio. Criar identidades externas reais é uma mutação de Auth e exige dados de acesso (e-mail) que não devem ser inventados. O código e o contrato podem ser preparados; a cerimônia real aguarda identidade controlada.
