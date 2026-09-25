-- CORBAN OS V2 — Import Staging & Lineage V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.
-- Raw source evidence is immutable; normalized/matching layers never overwrite source facts.

create table if not exists public.import_sources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  source_kind text not null check (source_kind in ('bank','correspondent','promotora','partner','legacy_system','manual','other')),
  source_entity_id uuid references public.commercial_entities(id),
  name text not null,
  external_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.import_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  source_id uuid not null references public.import_sources(id),
  original_filename text not null,
  content_sha256 text not null,
  storage_path text,
  mime_type text,
  parser_key text,
  parser_version text,
  status text not null default 'received' check (status in ('received','parsed','normalized','matching','ready_for_review','approved','applied','failed','rejected')),
  row_count integer,
  received_by uuid references auth.users(id),
  received_at timestamptz not null default now(),
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  unique (organization_id, content_sha256)
);

create table if not exists public.import_raw_rows (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  batch_id uuid not null references public.import_batches(id),
  row_number integer not null check (row_number > 0),
  raw_payload jsonb not null,
  raw_hash text not null,
  created_at timestamptz not null default now(),
  unique (organization_id,batch_id,row_number)
);

create table if not exists public.import_normalized_rows (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  raw_row_id uuid not null references public.import_raw_rows(id),
  record_kind text not null check (record_kind in ('table_offer','proposal','commission','payment','status','network_production','other')),
  bank_key text,
  external_proposal_number text,
  producer_tax_id text,
  external_table_code text,
  external_table_name text,
  operation_type text,
  term integer,
  rate numeric,
  commission_upfront numeric,
  commission_deferred numeric,
  amount numeric,
  normalized_payload jsonb not null default '{}'::jsonb,
  normalization_version text not null,
  created_at timestamptz not null default now(),
  unique (organization_id,raw_row_id,normalization_version)
);

create table if not exists public.import_match_candidates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  normalized_row_id uuid not null references public.import_normalized_rows(id),
  proposal_id uuid references public.proposals_v2(id),
  product_table_id uuid references public.product_tables(id),
  channel_id uuid references public.commercial_channels(id),
  producer_entity_id uuid references public.commercial_entities(id),
  match_strength text not null check (match_strength in ('exact','strong','probable','ambiguous','none')),
  match_basis jsonb not null,
  status text not null default 'suggested' check (status in ('suggested','accepted','rejected','human_required')),
  created_at timestamptz not null default now()
);

create table if not exists public.import_decisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  batch_id uuid not null references public.import_batches(id),
  normalized_row_id uuid references public.import_normalized_rows(id),
  candidate_id uuid references public.import_match_candidates(id),
  decision text not null check (decision in ('approve','reject','map','ignore','human_required')),
  reason text,
  decided_by uuid references auth.users(id),
  decided_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

alter table public.import_sources enable row level security;
alter table public.import_batches enable row level security;
alter table public.import_raw_rows enable row level security;
alter table public.import_normalized_rows enable row level security;
alter table public.import_match_candidates enable row level security;
alter table public.import_decisions enable row level security;

revoke all on public.import_sources,public.import_batches,public.import_raw_rows,public.import_normalized_rows,public.import_match_candidates,public.import_decisions from anon;

do $$
declare t text;
begin
 foreach t in array array['import_sources','import_batches','import_raw_rows','import_normalized_rows','import_match_candidates','import_decisions']
 loop
   execute format('create policy %I on public.%I for select to authenticated using (public.is_active_organization_member(organization_id))',t||'_select_member',t);
 end loop;
end $$;

-- Sources/config: manager+. Import evidence: active members can append, never rewrite raw evidence.
create policy import_sources_insert_manager on public.import_sources for insert to authenticated
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy import_sources_update_manager on public.import_sources for update to authenticated
using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

create policy import_batches_insert_member on public.import_batches for insert to authenticated
with check (public.is_active_organization_member(organization_id));
create policy import_raw_rows_insert_member on public.import_raw_rows for insert to authenticated
with check (public.is_active_organization_member(organization_id));
create policy import_normalized_rows_insert_member on public.import_normalized_rows for insert to authenticated
with check (public.is_active_organization_member(organization_id));
create policy import_match_candidates_insert_member on public.import_match_candidates for insert to authenticated
with check (public.is_active_organization_member(organization_id));
create policy import_decisions_insert_supervisor on public.import_decisions for insert to authenticated
with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

-- Cover expected tenant/source/lineage joins.
create index if not exists import_sources_org_entity_idx on public.import_sources(organization_id,source_entity_id);
create index if not exists import_batches_org_source_idx on public.import_batches(organization_id,source_id);
create index if not exists import_raw_rows_batch_idx on public.import_raw_rows(batch_id);
create index if not exists import_normalized_raw_idx on public.import_normalized_rows(raw_row_id);
create index if not exists import_normalized_proposal_number_idx on public.import_normalized_rows(organization_id,bank_key,external_proposal_number);
create index if not exists import_match_normalized_idx on public.import_match_candidates(normalized_row_id);
create index if not exists import_match_proposal_idx on public.import_match_candidates(proposal_id);
create index if not exists import_decisions_batch_idx on public.import_decisions(batch_id);
create index if not exists import_decisions_normalized_idx on public.import_decisions(normalized_row_id);
