-- CORBAN OS V2 — Financial Truth Ledger V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.
-- Append-only financial facts. Expected/reported/settled are distinct evidence.

create table if not exists public.financial_events (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 proposal_id uuid references public.proposals_v2(id),
 channel_id uuid references public.commercial_channels(id),
 producer_entity_id uuid references public.commercial_entities(id),
 payer_entity_id uuid references public.commercial_entities(id),
 event_type text not null check(event_type in ('commission_expected','network_share_expected','bonus_expected','commission_reported','payment_received','downstream_payable','downstream_paid','reversal','adjustment')),
 component_type text check(component_type in ('upfront','deferred','deferred_anticipation','campaign_bonus','volume_bonus','fixed','other')),
 amount numeric not null,
 currency text not null default 'BRL' check(currency ~ '^[A-Z]{3}$'),
 occurred_at timestamptz not null,
 idempotency_key text not null,
 source_kind text not null check(source_kind in ('proposal_snapshot','import','bank_report','partner_report','payment_evidence','manual_review','system')),
 source_reference text,
 reverses_event_id uuid references public.financial_events(id),
 metadata jsonb not null default '{}'::jsonb,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,idempotency_key),
 check(amount>=0),
 check((event_type='reversal')=(reverses_event_id is not null))
);

create table if not exists public.financial_evidence_links (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 financial_event_id uuid not null references public.financial_events(id),
 import_batch_id uuid references public.import_batches(id),
 import_raw_row_id uuid references public.import_raw_rows(id),
 import_decision_id uuid references public.import_decisions(id),
 evidence_kind text not null,
 evidence_reference text,
 created_at timestamptz not null default now(),
 check(import_batch_id is not null or import_raw_row_id is not null or import_decision_id is not null or evidence_reference is not null)
);

create table if not exists public.financial_reconciliation_cases (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 proposal_id uuid references public.proposals_v2(id),
 channel_id uuid references public.commercial_channels(id),
 component_type text,
 expected_amount numeric,
 reported_amount numeric,
 settled_amount numeric,
 divergence_amount numeric generated always as (coalesce(settled_amount,reported_amount,0)-coalesce(expected_amount,0)) stored,
 status text not null default 'open' check(status in ('open','matched','divergent','human_required','resolved')),
 resolution_note text,
 resolved_by uuid references auth.users(id),
 resolved_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(expected_amount is null or expected_amount>=0),
 check(reported_amount is null or reported_amount>=0),
 check(settled_amount is null or settled_amount>=0)
);

alter table public.financial_events enable row level security;
alter table public.financial_evidence_links enable row level security;
alter table public.financial_reconciliation_cases enable row level security;
revoke all on public.financial_events,public.financial_evidence_links,public.financial_reconciliation_cases from anon;

create policy financial_events_select_member on public.financial_events for select to authenticated using(public.is_active_organization_member(organization_id));
create policy financial_evidence_links_select_member on public.financial_evidence_links for select to authenticated using(public.is_active_organization_member(organization_id));
create policy financial_reconciliation_cases_select_member on public.financial_reconciliation_cases for select to authenticated using(public.is_active_organization_member(organization_id));

-- Events/evidence are append-only and supervisor+; no authenticated UPDATE/DELETE.
create policy financial_events_insert_supervisor on public.financial_events for insert to authenticated with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']) and created_by=auth.uid());
create policy financial_evidence_links_insert_supervisor on public.financial_evidence_links for insert to authenticated with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy financial_reconciliation_cases_insert_supervisor on public.financial_reconciliation_cases for insert to authenticated with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy financial_reconciliation_cases_update_supervisor on public.financial_reconciliation_cases for update to authenticated using(public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])) with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

create index if not exists financial_events_org_proposal_idx on public.financial_events(organization_id,proposal_id,occurred_at);
create index if not exists financial_events_channel_idx on public.financial_events(channel_id);
create index if not exists financial_events_producer_idx on public.financial_events(producer_entity_id);
create index if not exists financial_events_payer_idx on public.financial_events(payer_entity_id);
create index if not exists financial_events_reversal_idx on public.financial_events(reverses_event_id);
create index if not exists financial_events_created_by_idx on public.financial_events(created_by);
create index if not exists financial_evidence_event_idx on public.financial_evidence_links(financial_event_id);
create index if not exists financial_evidence_batch_idx on public.financial_evidence_links(import_batch_id);
create index if not exists financial_evidence_raw_idx on public.financial_evidence_links(import_raw_row_id);
create index if not exists financial_evidence_decision_idx on public.financial_evidence_links(import_decision_id);
create index if not exists financial_reconciliation_org_status_idx on public.financial_reconciliation_cases(organization_id,status);
create index if not exists financial_reconciliation_proposal_idx on public.financial_reconciliation_cases(proposal_id);
create index if not exists financial_reconciliation_channel_idx on public.financial_reconciliation_cases(channel_id);
create index if not exists financial_reconciliation_resolved_by_idx on public.financial_reconciliation_cases(resolved_by);
