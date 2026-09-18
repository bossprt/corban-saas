-- CORBAN OS V2 — Internal Digitization + Operational Pipeline V0
-- Prepared only. Depends on Proposal V0 + Document Vault V0.

-- Technical stages are tenant configurable visually but retain canonical technical meaning.
create table if not exists public.operational_stages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code text not null,
  name text not null,
  canonical_state text not null,
  sort_order integer not null default 0,
  sla_minutes integer,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_stages_canonical_check check (canonical_state in (
    'digitization_queue','digitizing','submitted','pending_external',
    'approved','paid','cancelled','rejected'
  )),
  constraint operational_stages_sort_check check (sort_order >= 0),
  constraint operational_stages_sla_check check (sla_minutes is null or sla_minutes >= 0),
  constraint operational_stages_org_code_key unique (organization_id, code),
  constraint operational_stages_org_id_key unique (organization_id, id)
);

-- Proposal V0 must expose tenant composite identity before operational FKs.
create unique index if not exists proposals_v2_org_id_key on public.proposals_v2 (organization_id, id);

create table if not exists public.digitization_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  proposal_id uuid not null,
  status text not null default 'queued',
  priority integer not null default 0,
  assigned_to uuid references auth.users(id) on delete set null,
  external_reference text,
  attempt_count integer not null default 0,
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  submitted_at timestamptz,
  completed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint digitization_jobs_proposal_tenant_fk foreign key (organization_id, proposal_id)
    references public.proposals_v2 (organization_id, id) on delete restrict,
  constraint digitization_jobs_status_check check (status in ('queued','assigned','in_progress','blocked','submitted','completed','cancelled')),
  constraint digitization_jobs_priority_check check (priority >= 0),
  constraint digitization_jobs_attempt_check check (attempt_count >= 0)
);

create unique index if not exists digitization_jobs_org_id_key on public.digitization_jobs (organization_id, id);
create unique index if not exists digitization_jobs_active_proposal_key
  on public.digitization_jobs (organization_id, proposal_id)
  where status in ('queued','assigned','in_progress','blocked','submitted');
create index if not exists digitization_jobs_org_status_priority_idx
  on public.digitization_jobs (organization_id, status, priority desc, queued_at);

-- Current operational position. History lives in append-only events below.
create table if not exists public.operational_cases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  proposal_id uuid not null,
  digitization_job_id uuid,
  current_stage_id uuid not null,
  canonical_state text not null,
  owner_user_id uuid references auth.users(id) on delete set null,
  entered_stage_at timestamptz not null default now(),
  due_at timestamptz,
  external_status_raw text,
  external_status_source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_cases_proposal_tenant_fk foreign key (organization_id, proposal_id)
    references public.proposals_v2 (organization_id, id) on delete restrict,
  constraint operational_cases_digitization_tenant_fk foreign key (organization_id, digitization_job_id)
    references public.digitization_jobs (organization_id, id) on delete restrict,
  constraint operational_cases_stage_tenant_fk foreign key (organization_id, current_stage_id)
    references public.operational_stages (organization_id, id) on delete restrict,
  constraint operational_cases_state_check check (canonical_state in (
    'digitization_queue','digitizing','submitted','pending_external',
    'approved','paid','cancelled','rejected'
  )),
  constraint operational_cases_proposal_key unique (organization_id, proposal_id)
);

create unique index if not exists operational_cases_org_id_key on public.operational_cases (organization_id, id);
create index if not exists operational_cases_org_stage_due_idx on public.operational_cases (organization_id, current_stage_id, due_at);
create index if not exists operational_cases_org_state_idx on public.operational_cases (organization_id, canonical_state);

-- Immutable operational timeline: state changes, assignments, external status normalization, blocks.
create table if not exists public.operational_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  operational_case_id uuid not null,
  event_type text not null,
  from_state text,
  to_state text,
  raw_external_status text,
  source text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint operational_events_case_tenant_fk foreign key (organization_id, operational_case_id)
    references public.operational_cases (organization_id, id) on delete restrict
);

create index if not exists operational_events_case_time_idx on public.operational_events (organization_id, operational_case_id, occurred_at desc);

alter table public.operational_stages enable row level security;
alter table public.digitization_jobs enable row level security;
alter table public.operational_cases enable row level security;
alter table public.operational_events enable row level security;

revoke all on table public.operational_stages, public.digitization_jobs, public.operational_cases, public.operational_events from anon;
grant select, insert, update on table public.operational_stages, public.digitization_jobs, public.operational_cases to authenticated;
grant select, insert on table public.operational_events to authenticated;

create policy operational_stages_select_member on public.operational_stages for select to authenticated using (public.is_active_organization_member(organization_id));
create policy operational_stages_insert_member on public.operational_stages for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy operational_stages_update_member on public.operational_stages for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy digitization_jobs_select_member on public.digitization_jobs for select to authenticated using (public.is_active_organization_member(organization_id));
create policy digitization_jobs_insert_member on public.digitization_jobs for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy digitization_jobs_update_member on public.digitization_jobs for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy operational_cases_select_member on public.operational_cases for select to authenticated using (public.is_active_organization_member(organization_id));
create policy operational_cases_insert_member on public.operational_cases for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy operational_cases_update_member on public.operational_cases for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy operational_events_select_member on public.operational_events for select to authenticated using (public.is_active_organization_member(organization_id));
create policy operational_events_insert_member on public.operational_events for insert to authenticated with check (public.is_active_organization_member(organization_id));

-- No authenticated DELETE. Event history is append-only by grant/policy.
-- State transition guards and "documents ready before queue" domain guard are required before production.
