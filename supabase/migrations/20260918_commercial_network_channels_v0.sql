-- CORBAN OS V2 — Commercial Network & Channel Model V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.

create table if not exists public.commercial_entities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  legal_name text not null,
  trade_name text,
  tax_id text,
  entity_kind text not null check (entity_kind in ('bank','correspondent','promotora','partner','broker','indicator','association','other')),
  is_internal boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, tax_id)
);

create table if not exists public.commercial_relationships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  upstream_entity_id uuid not null references public.commercial_entities(id),
  downstream_entity_id uuid not null references public.commercial_entities(id),
  bank_id uuid references public.banks(id),
  relationship_role text not null check (relationship_role in ('master','subestablished','partner','broker','indicator','other')),
  effective_from timestamptz not null,
  effective_until timestamptz,
  is_active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (upstream_entity_id <> downstream_entity_id),
  check (effective_until is null or effective_until > effective_from)
);

create table if not exists public.commercial_channels (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  bank_id uuid not null references public.banks(id),
  relationship_id uuid references public.commercial_relationships(id),
  name text not null,
  external_partner_code text,
  payer_entity_id uuid references public.commercial_entities(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.product_table_external_identities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  product_table_id uuid not null references public.product_tables(id),
  channel_id uuid not null references public.commercial_channels(id),
  external_code text not null,
  external_name text,
  effective_from timestamptz not null,
  effective_until timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, channel_id, external_code),
  check (effective_until is null or effective_until > effective_from)
);

create table if not exists public.channel_commission_rule_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  channel_id uuid not null references public.commercial_channels(id),
  product_table_id uuid not null references public.product_tables(id),
  version integer not null check (version > 0),
  status text not null default 'draft' check (status in ('draft','published','retired')),
  operation_type text,
  term_min integer,
  term_max integer,
  rate numeric,
  effective_from timestamptz,
  effective_until timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, channel_id, product_table_id, version),
  check (term_min is null or term_min > 0),
  check (term_max is null or term_max >= term_min),
  check (effective_until is null or effective_from is null or effective_until > effective_from)
);

create table if not exists public.commission_rule_components (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  rule_version_id uuid not null references public.channel_commission_rule_versions(id),
  component_type text not null check (component_type in ('upfront','deferred','deferred_anticipation','campaign_bonus','volume_bonus','fixed','other')),
  percentage numeric,
  fixed_amount numeric,
  anticipation_factor numeric,
  calculation_base text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (percentage is null or percentage >= 0),
  check (fixed_amount is null or fixed_amount >= 0),
  check (anticipation_factor is null or anticipation_factor >= 0)
);

create table if not exists public.network_split_rule_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  relationship_id uuid not null references public.commercial_relationships(id),
  bank_id uuid references public.banks(id),
  product_table_id uuid references public.product_tables(id),
  component_type text,
  version integer not null check (version > 0),
  downstream_share numeric not null check (downstream_share >= 0 and downstream_share <= 1),
  upstream_share numeric not null check (upstream_share >= 0 and upstream_share <= 1),
  payment_flow text not null check (payment_flow in ('direct_by_payer','through_upstream','through_downstream','other')),
  effective_from timestamptz not null,
  effective_until timestamptz,
  status text not null default 'draft' check (status in ('draft','published','retired')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (downstream_share + upstream_share = 1),
  check (effective_until is null or effective_until > effective_from)
);

create table if not exists public.proposal_external_identities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  proposal_id uuid not null references public.proposals_v2(id),
  institution_key text not null,
  external_proposal_number text not null,
  channel_id uuid references public.commercial_channels(id),
  source text,
  first_seen_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  unique (organization_id, institution_key, external_proposal_number)
);

create table if not exists public.proposal_commercial_snapshots (
  proposal_id uuid primary key references public.proposals_v2(id),
  organization_id uuid not null references public.organizations(id),
  channel_id uuid not null references public.commercial_channels(id),
  commission_rule_version_id uuid references public.channel_commission_rule_versions(id),
  producer_entity_id uuid references public.commercial_entities(id),
  payer_entity_id uuid references public.commercial_entities(id),
  split_rule_version_id uuid references public.network_split_rule_versions(id),
  snapshot jsonb not null,
  created_at timestamptz not null default now()
);

-- RLS fail-closed baseline. Policies are deliberately explicit.
alter table public.commercial_entities enable row level security;
alter table public.commercial_relationships enable row level security;
alter table public.commercial_channels enable row level security;
alter table public.product_table_external_identities enable row level security;
alter table public.channel_commission_rule_versions enable row level security;
alter table public.commission_rule_components enable row level security;
alter table public.network_split_rule_versions enable row level security;
alter table public.proposal_external_identities enable row level security;
alter table public.proposal_commercial_snapshots enable row level security;

-- No anon access.
revoke all on public.commercial_entities, public.commercial_relationships, public.commercial_channels,
 public.product_table_external_identities, public.channel_commission_rule_versions,
 public.commission_rule_components, public.network_split_rule_versions,
 public.proposal_external_identities, public.proposal_commercial_snapshots from anon;

-- Tenant reads.
do $$
declare t text;
begin
 foreach t in array array['commercial_entities','commercial_relationships','commercial_channels','product_table_external_identities','channel_commission_rule_versions','commission_rule_components','network_split_rule_versions','proposal_external_identities','proposal_commercial_snapshots']
 loop
   execute format('create policy %I on public.%I for select to authenticated using (public.is_active_organization_member(organization_id))', t || '_select_member', t);
 end loop;
end $$;

-- Critical commercial configuration writes: admin/manager only.
do $$
declare t text;
begin
 foreach t in array array['commercial_entities','commercial_relationships','commercial_channels','product_table_external_identities','channel_commission_rule_versions','commission_rule_components','network_split_rule_versions']
 loop
   execute format('create policy %I on public.%I for insert to authenticated with check (public.has_active_organization_role(organization_id, array[''admin'',''manager'']))', t || '_insert_manager', t);
   execute format('create policy %I on public.%I for update to authenticated using (public.has_active_organization_role(organization_id, array[''admin'',''manager''])) with check (public.has_active_organization_role(organization_id, array[''admin'',''manager'']))', t || '_update_manager', t);
 end loop;
end $$;

-- Proposal identities/snapshots are append-oriented. No authenticated UPDATE/DELETE.
create policy proposal_external_identities_insert_member on public.proposal_external_identities
for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy proposal_commercial_snapshots_insert_member on public.proposal_commercial_snapshots
for insert to authenticated with check (public.is_active_organization_member(organization_id));
