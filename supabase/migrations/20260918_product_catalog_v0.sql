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
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agreements_code_key unique (code)
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
  constraint modalities_product_code_key unique (product_id, code)
);

-- Tenant-scoped route/configuration. This is the bridge between global catalog and a Corban.
create table if not exists public.organization_product_routes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  bank_id uuid not null references public.banks(id) on delete restrict,
  provider_id uuid not null references public.providers(id) on delete restrict,
  agreement_id uuid not null references public.agreements(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  modality_id uuid not null references public.modalities(id) on delete restrict,
  status text not null default 'active',
  external_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_product_routes_status_check check (status in ('active','inactive')),
  constraint organization_product_routes_unique
    unique (organization_id, bank_id, provider_id, agreement_id, product_id, modality_id)
);

create index if not exists organization_product_routes_org_status_idx
  on public.organization_product_routes (organization_id, status);

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

create unique index if not exists organization_product_routes_org_id_key
  on public.organization_product_routes (organization_id, id);

-- Note: FK above requires the composite unique index. PostgreSQL validates referenced
-- uniqueness at table creation time, so the route composite unique index must exist first.
