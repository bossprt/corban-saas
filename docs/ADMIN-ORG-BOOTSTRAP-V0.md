# ADMIN ORGANIZATION BOOTSTRAP V0

A criação de Organization + Membership + profile legado é transacional dentro do Postgres via `bootstrap_organization_admin`. A função é SECURITY DEFINER por necessidade de escrever a fundação do tenant, mas EXECUTE é revogado de public/anon/authenticated e concedido apenas a service_role.

A identidade Auth é criada por `inviteUserByEmail` no servidor. Supabase documenta que operações `auth.admin` exigem ambiente servidor e service_role nunca deve ir ao browser.

Como Auth e Postgres não compartilham a mesma transação, o endpoint aplica compensação: se o bootstrap SQL falhar depois do convite, remove a identidade recém-criada para evitar usuário órfão.

O endpoint não é signup público. O chamador precisa estar autenticado **e registrado como `platform_administrators.status=active`**. Admin de tenant não recebe autoridade para criar outro tenant. Nenhum organization_id vem confiado do cliente; o UUID da organização é criado pelo banco. O bootstrap grava evento append-only `organization.bootstrap_admin` com o operador responsável.

**Não aplicado/deployado ainda:** a migration e o endpoint estão preparados no branch. A service role não foi lida, criada nem gravada no Git.
