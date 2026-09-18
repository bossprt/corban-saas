-- CORBAN OS V2 — migrate legacy RLS policies to explicit active memberships
-- PRECONDITION: authenticated A/B tenant isolation gate must pass before application.
-- This file is intentionally NOT applied yet.

-- organizations
drop policy if exists "Isolamento de Organizacoes" on public.organizations;
create policy organizations_select_member on public.organizations
for select to authenticated
using (public.is_active_organization_member(id));

-- profiles: read profiles only inside an organization where caller has active membership.
drop policy if exists "Isolamento de Perfis" on public.profiles;
create policy profiles_select_member on public.profiles
for select to authenticated
using (public.is_active_organization_member(organization_id));

-- clients
drop policy if exists "Isolamento de Clientes" on public.clients;
create policy clients_select_member on public.clients
for select to authenticated
using (public.is_active_organization_member(organization_id));

create policy clients_insert_member on public.clients
for insert to authenticated
with check (public.is_active_organization_member(organization_id));

create policy clients_update_member on public.clients
for update to authenticated
using (public.is_active_organization_member(organization_id))
with check (public.is_active_organization_member(organization_id));

-- DELETE intentionally omitted in V2 policy migration until Customer soft-delete model exists.

-- contracts: legacy table remains readable/updatable during transition, but direct DELETE omitted.
drop policy if exists "Isolamento de Contratos" on public.contracts;
create policy contracts_select_member on public.contracts
for select to authenticated
using (public.is_active_organization_member(organization_id));

create policy contracts_insert_member on public.contracts
for insert to authenticated
with check (public.is_active_organization_member(organization_id));

create policy contracts_update_member on public.contracts
for update to authenticated
using (public.is_active_organization_member(organization_id))
with check (public.is_active_organization_member(organization_id));

-- import jobs
drop policy if exists "Isolamento de Importacoes" on public.import_jobs;
create policy import_jobs_select_member on public.import_jobs
for select to authenticated
using (public.is_active_organization_member(organization_id));

create policy import_jobs_insert_member on public.import_jobs
for insert to authenticated
with check (public.is_active_organization_member(organization_id));

create policy import_jobs_update_member on public.import_jobs
for update to authenticated
using (public.is_active_organization_member(organization_id))
with check (public.is_active_organization_member(organization_id));

-- The legacy helper can only be retired in a later migration after verifying
-- that no policy/function/application path depends on it.
