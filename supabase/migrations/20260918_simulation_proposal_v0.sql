-- CORBAN OS V2 — Simulation / Proposal V0
-- Prepared only. Depends on Customer 360 + Product Catalog V0.

create table if not exists public.simulations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null,
  product_table_version_id uuid not null,
  status text not null default 'draft',
  requested_amount numeric(14,2),
  released_amount numeric(14,2),
  installment_amount numeric(14,2),
  term integer,
  rate numeric(12,8),
  coefficient numeric(18,10),
  expected_commission_amount numeric(14,2),
  input_snapshot jsonb not null default '{}'::jsonb,
  result_snapshot jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint simulations_status_check check (status in ('draft','calculated','selected','expired','cancelled')),
  constraint simulations_amounts_check check (
    (requested_amount is null or requested_amount >= 0) and
    (released_amount is null or released_amount >= 0) and
    (installment_amount is null or installment_amount >= 0) and
    (expected_commission_amount is null or expected_commission_amount >= 0)
  ),
  constraint simulations_term_check check (term is null or term > 0),
  constraint simulations_customer_tenant_fk foreign key (organization_id, customer_id)
    references public.clients (organization_id, id) on delete restrict
);

-- Product Catalog V0 provides product_table_versions_org_id_key.
alter table public.simulations
  add constraint simulations_table_version_tenant_fk
  foreign key (organization_id, product_table_version_id)
  references public.product_table_versions (organization_id, id) on delete restrict;

create unique index if not exists simulations_org_id_key on public.simulations (organization_id, id);
create unique index if not exists simulations_org_id_customer_table_key
  on public.simulations (organization_id, id, customer_id, product_table_version_id);
create index if not exists simulations_org_customer_created_idx on public.simulations (organization_id, customer_id, created_at desc);
create index if not exists simulations_org_table_version_idx on public.simulations (organization_id, product_table_version_id);
create index if not exists simulations_created_by_idx on public.simulations (created_by);
create index if not exists simulations_org_status_idx on public.simulations (organization_id, status);

create table if not exists public.proposals_v2 (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null,
  simulation_id uuid,
  product_table_version_id uuid not null,
  status text not null default 'draft',
  external_proposal_id text,
  requested_amount numeric(14,2),
  released_amount numeric(14,2),
  installment_amount numeric(14,2),
  term integer,
  rate numeric(12,8),
  coefficient numeric(18,10),
  expected_commission_amount numeric(14,2),
  customer_snapshot jsonb not null,
  commercial_snapshot jsonb not null,
  attribution_snapshot jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint proposals_v2_status_check check (status in ('draft','documents_pending','ready_for_digitization','digitization','submitted','approved','paid','cancelled')),
  constraint proposals_v2_amounts_check check (
    (requested_amount is null or requested_amount >= 0) and
    (released_amount is null or released_amount >= 0) and
    (installment_amount is null or installment_amount >= 0) and
    (expected_commission_amount is null or expected_commission_amount >= 0)
  ),
  constraint proposals_v2_term_check check (term is null or term > 0),
  constraint proposals_v2_customer_tenant_fk foreign key (organization_id, customer_id)
    references public.clients (organization_id, id) on delete restrict,
  constraint proposals_v2_simulation_tenant_fk foreign key (organization_id, simulation_id)
    references public.simulations (organization_id, id) on delete restrict,
  constraint proposals_v2_simulation_snapshot_fk
    foreign key (organization_id, simulation_id, customer_id, product_table_version_id)
    references public.simulations (organization_id, id, customer_id, product_table_version_id) on delete restrict,
  constraint proposals_v2_table_version_tenant_fk foreign key (organization_id, product_table_version_id)
    references public.product_table_versions (organization_id, id) on delete restrict
);

create unique index if not exists proposals_v2_org_id_key on public.proposals_v2 (organization_id, id);
create index if not exists proposals_v2_org_customer_created_idx on public.proposals_v2 (organization_id, customer_id, created_at desc);
create index if not exists proposals_v2_org_status_idx on public.proposals_v2 (organization_id, status);
create index if not exists proposals_v2_org_simulation_idx on public.proposals_v2 (organization_id, simulation_id);
create index if not exists proposals_v2_created_by_idx on public.proposals_v2 (created_by);
create index if not exists proposals_v2_org_table_version_idx on public.proposals_v2 (organization_id, product_table_version_id);
create unique index if not exists proposals_v2_org_external_id_key
  on public.proposals_v2 (organization_id, external_proposal_id)
  where external_proposal_id is not null;

create or replace function public.guard_proposal_commercial_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if not exists (
    select 1 from public.product_table_versions v
    where v.organization_id = new.organization_id
      and v.id = new.product_table_version_id
      and v.status = 'published'
  ) then
    raise exception 'proposal_requires_published_product_table_version';
  end if;

  if tg_op = 'UPDATE' and old.status <> 'draft' then
    if new.status = 'draft' then
      raise exception 'proposal_cannot_return_to_draft';
    end if;
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.simulation_id is distinct from old.simulation_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.expected_commission_amount is distinct from old.expected_commission_amount
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.commercial_snapshot is distinct from old.commercial_snapshot
       or new.attribution_snapshot is distinct from old.attribution_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'proposal_commercial_snapshot_is_immutable_after_draft';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists proposals_v2_commercial_snapshot_guard on public.proposals_v2;
create trigger proposals_v2_commercial_snapshot_guard
before insert or update on public.proposals_v2
for each row execute function public.guard_proposal_commercial_snapshot();

revoke all on function public.guard_proposal_commercial_snapshot() from public, anon, authenticated;

alter table public.simulations enable row level security;
alter table public.proposals_v2 enable row level security;

revoke all on table public.simulations from anon;
revoke all on table public.proposals_v2 from anon;
grant select, insert, update on table public.simulations to authenticated;
grant select, insert, update on table public.proposals_v2 to authenticated;

create policy simulations_select_member on public.simulations for select to authenticated using (public.is_active_organization_member(organization_id));
create policy simulations_insert_member on public.simulations for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy simulations_update_member on public.simulations for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy proposals_v2_select_member on public.proposals_v2 for select to authenticated using (public.is_active_organization_member(organization_id));
create policy proposals_v2_insert_member on public.proposals_v2 for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy proposals_v2_update_member on public.proposals_v2 for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

-- Explicit maintenance privileges; do not depend on owner/default privilege behavior.
grant select, insert, update, delete on table public.simulations, public.proposals_v2 to service_role;

-- No authenticated DELETE. Proposal cancellation is a state transition, not row deletion.
