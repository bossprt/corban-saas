-- CORBAN OS V2 — additive indexes for legacy foreign keys / tenant filters
-- Safe additive performance migration.

create index if not exists contracts_client_id_idx on public.contracts (client_id);
create index if not exists contracts_organization_id_idx on public.contracts (organization_id);
create index if not exists contracts_user_id_idx on public.contracts (user_id);
create index if not exists import_jobs_organization_id_idx on public.import_jobs (organization_id);
create index if not exists profiles_organization_id_idx on public.profiles (organization_id);
