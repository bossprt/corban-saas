-- CORBAN OS V2 — Customer 360 additive foundation
-- Prepared only; do not apply before Tenant A/B authenticated isolation gate passes.

-- Extend legacy clients into canonical Customer without destroying legacy data.
alter table public.clients
  add column if not exists preferred_name text,
  add column if not exists secondary_phone text,
  add column if not exists source text,
  add column if not exists notes text,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists deleted_at timestamptz;

-- Replace legacy hard UNIQUE only in a dedicated migration after checking its exact
-- constraint name/state and after tenant gate. ADR-0005 requires partial uniqueness:
-- (organization_id, cpf) where deleted_at is null.

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null references public.clients(id) on delete restrict,
  label text,
  postal_code text,
  street text,
  number text,
  complement text,
  neighborhood text,
  city text,
  state text,
  country_code text not null default 'BR',
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists customer_addresses_org_customer_idx
  on public.customer_addresses (organization_id, customer_id);

create table if not exists public.customer_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null references public.clients(id) on delete restrict,
  bank_code text,
  bank_name text not null,
  branch text,
  account_number text,
  account_digit text,
  account_type text,
  holder_name text,
  holder_document text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists customer_bank_accounts_org_customer_idx
  on public.customer_bank_accounts (organization_id, customer_id);

create table if not exists public.customer_pix_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null references public.clients(id) on delete restrict,
  bank_account_id uuid references public.customer_bank_accounts(id) on delete set null,
  key_type text not null,
  key_value text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_pix_keys_type_check
    check (key_type in ('cpf','cnpj','phone','email','random'))
);

create index if not exists customer_pix_keys_org_customer_idx
  on public.customer_pix_keys (organization_id, customer_id);
create index if not exists customer_pix_keys_bank_account_idx
  on public.customer_pix_keys (bank_account_id);

create table if not exists public.customer_timeline_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null references public.clients(id) on delete restrict,
  event_type text not null,
  source text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists customer_timeline_org_customer_time_idx
  on public.customer_timeline_events (organization_id, customer_id, occurred_at desc);
create index if not exists customer_timeline_actor_idx
  on public.customer_timeline_events (actor_user_id);

alter table public.customer_addresses enable row level security;
alter table public.customer_bank_accounts enable row level security;
alter table public.customer_pix_keys enable row level security;
alter table public.customer_timeline_events enable row level security;

-- Explicit operation policies using active membership.
create policy customer_addresses_select_member on public.customer_addresses for select to authenticated using (public.is_active_organization_member(organization_id));
create policy customer_addresses_insert_member on public.customer_addresses for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy customer_addresses_update_member on public.customer_addresses for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy customer_bank_accounts_select_member on public.customer_bank_accounts for select to authenticated using (public.is_active_organization_member(organization_id));
create policy customer_bank_accounts_insert_member on public.customer_bank_accounts for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy customer_bank_accounts_update_member on public.customer_bank_accounts for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy customer_pix_keys_select_member on public.customer_pix_keys for select to authenticated using (public.is_active_organization_member(organization_id));
create policy customer_pix_keys_insert_member on public.customer_pix_keys for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy customer_pix_keys_update_member on public.customer_pix_keys for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy customer_timeline_select_member on public.customer_timeline_events for select to authenticated using (public.is_active_organization_member(organization_id));
create policy customer_timeline_insert_member on public.customer_timeline_events for insert to authenticated with check (public.is_active_organization_member(organization_id));

-- No DELETE policies. Soft-delete / immutable timeline behavior will be enforced by domain services and later DB guards.
