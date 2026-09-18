-- CORBAN OS V2 — Bank / Provider / Agreement / Product / Modality / Table catalog
-- Prepared only; do not apply before tenant security gate and controlled migration sequence.

-- Platform catalog: no organization_id. Tenant enablement is separate.
create table if not exists public.banks (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint banks_code_key unique (code)
);

create table if not exists public.providers (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  provider_type text not null default 'master',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint providers_code_key unique (code),
  constraint providers_type_check check (provider_type in ('bank_direct','master','promotora','other'))
);

create table if not exists public.agreements (
  id uuid primary key default gen_random_uuid(),
  bank_id uuid not null references public.banks(id) on delete restrict,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agreements_bank_code_key unique (bank_id, code),
  constraint agreements_bank_id_id_key unique (bank_id, id)
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_code_key unique (code)
);

create table if not exists public.modalities (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint modalities_product_code_key unique (product_id, code),
  constraint modalities_product_id_id_key unique (product_id, id)
);

-- Tenant-scoped route/configuration. This is the bridge between global catalog and a Corban.
create table if not exists public.organization_product_routes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  bank_id uuid not null references public.banks(id) on delete restrict,
  provider_id uuid not null references public.providers(id) on delete restrict,
  agreement_id uuid not null,
  product_id uuid not null references public.products(id) on delete restrict,
  modality_id uuid not null,
  status text not null default 'active',
  external_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_product_routes_status_check check (status in ('active','inactive')),
  constraint organization_product_routes_agreement_bank_fk
    foreign key (bank_id, agreement_id)
    references public.agreements (bank_id, id) on delete restrict,
  constraint organization_product_routes_modality_product_fk
    foreign key (product_id, modality_id)
    references public.modalities (product_id, id) on delete restrict,
  constraint organization_product_routes_unique
    unique (organization_id, bank_id, provider_id, agreement_id, product_id, modality_id)
);

create index if not exists agreements_bank_id_idx on public.agreements (bank_id);

create index if not exists organization_product_routes_org_status_idx
  on public.organization_product_routes (organization_id, status);

create unique index if not exists organization_product_routes_org_id_key
  on public.organization_product_routes (organization_id, id);

-- Logical table identity belongs to a tenant route. Versions are immutable snapshots.
create table if not exists public.product_tables (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  route_id uuid not null,
  code text not null,
  name text not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_tables_status_check check (status in ('active','archived')),
  constraint product_tables_org_code_key unique (organization_id, code),
  constraint product_tables_org_id_key unique (organization_id, id),
  constraint product_tables_route_tenant_fk
    foreign key (organization_id, route_id)
    references public.organization_product_routes (organization_id, id) on delete restrict
);


create table if not exists public.product_table_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  product_table_id uuid not null,
  version integer not null,
  status text not null default 'draft',
  effective_from timestamptz,
  effective_until timestamptz,
  term_min integer,
  term_max integer,
  rate numeric(12,8),
  coefficient numeric(18,10),
  metadata jsonb not null default '{}'::jsonb,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  constraint product_table_versions_status_check check (status in ('draft','published','superseded','expired')),
  constraint product_table_versions_version_check check (version > 0),
  constraint product_table_versions_term_check check (term_min is null or term_max is null or term_min <= term_max),
  constraint product_table_versions_rate_check check (rate is null or rate >= 0),
  constraint product_table_versions_coefficient_check check (coefficient is null or coefficient >= 0),
  constraint product_table_versions_table_tenant_fk
    foreign key (organization_id, product_table_id)
    references public.product_tables (organization_id, id) on delete restrict,
  constraint product_table_versions_table_version_key
    unique (product_table_id, version)
);

create index if not exists product_table_versions_org_status_idx
  on public.product_table_versions (organization_id, status);
create index if not exists product_table_versions_table_effective_idx
  on public.product_table_versions (product_table_id, effective_from desc);
create unique index if not exists product_table_versions_org_id_key
  on public.product_table_versions (organization_id, id);

alter table public.organization_product_routes enable row level security;
alter table public.product_tables enable row level security;
alter table public.product_table_versions enable row level security;

revoke all on table public.organization_product_routes from anon;
revoke all on table public.product_tables from anon;
revoke all on table public.product_table_versions from anon;

grant select, insert, update on table public.organization_product_routes to authenticated;
grant select, insert, update on table public.product_tables to authenticated;
grant select, insert, update on table public.product_table_versions to authenticated;

create policy organization_product_routes_select_member on public.organization_product_routes for select to authenticated using (public.is_active_organization_member(organization_id));
create policy organization_product_routes_insert_member on public.organization_product_routes for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy organization_product_routes_update_member on public.organization_product_routes for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy product_tables_select_member on public.product_tables for select to authenticated using (public.is_active_organization_member(organization_id));
create policy product_tables_insert_member on public.product_tables for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy product_tables_update_member on public.product_tables for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy product_table_versions_select_member on public.product_table_versions for select to authenticated using (public.is_active_organization_member(organization_id));
create policy product_table_versions_insert_member on public.product_table_versions for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy product_table_versions_update_draft_member on public.product_table_versions for update to authenticated
  using (public.is_active_organization_member(organization_id) and status = 'draft')
  with check (public.is_active_organization_member(organization_id) and status = 'draft');

-- Defense in depth: once a version leaves draft, its commercial snapshot is immutable.
-- Status lifecycle changes for published/superseded/expired must use a later controlled
-- publication primitive that explicitly bypasses this trigger for status metadata only.
create or replace function public.guard_product_table_version_immutable()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.status <> 'draft' then
    if new.organization_id is distinct from old.organization_id
       or new.product_table_id is distinct from old.product_table_id
       or new.version is distinct from old.version
       or new.effective_from is distinct from old.effective_from
       or new.effective_until is distinct from old.effective_until
       or new.term_min is distinct from old.term_min
       or new.term_max is distinct from old.term_max
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.metadata is distinct from old.metadata
       or new.created_at is distinct from old.created_at then
      raise exception 'published_product_table_version_is_immutable';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists product_table_versions_immutable_guard on public.product_table_versions;
create trigger product_table_versions_immutable_guard
before update on public.product_table_versions
for each row execute function public.guard_product_table_version_immutable();

revoke all on function public.guard_product_table_version_immutable() from public, anon, authenticated;

-- Global catalog tables are deliberately not exposed directly to authenticated writes in V0.
revoke all on table public.banks from anon, authenticated;
revoke all on table public.providers from anon, authenticated;
revoke all on table public.agreements from anon, authenticated;
revoke all on table public.products from anon, authenticated;
revoke all on table public.modalities from anon, authenticated;
grant select on table public.banks, public.providers, public.agreements, public.products, public.modalities to authenticated;

-- Explicit maintenance privileges; do not depend on owner/default privilege behavior.
grant select, insert, update, delete on table public.banks, public.providers, public.agreements, public.products, public.modalities to service_role;
grant select, insert, update, delete on table public.organization_product_routes, public.product_tables, public.product_table_versions to service_role;
