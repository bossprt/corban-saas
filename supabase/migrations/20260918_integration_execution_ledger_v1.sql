-- Mirror of live migration 20260918214750 integration_execution_ledger_v1 (already applied).
-- Repository reconciliation only; do not re-apply as new history.
create table public.integration_runs (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 binding_id uuid not null references public.integration_source_bindings(id),
 adapter_id uuid not null references public.integration_adapters(id),
 capability text not null,
 status text not null default 'queued' check (status in ('queued','running','succeeded','failed','cancelled')),
 request_fingerprint text not null,
 external_request_id text,
 started_at timestamptz,
 finished_at timestamptz,
 attempt_count integer not null default 0 check (attempt_count >= 0),
 max_attempts integer not null default 3 check (max_attempts between 1 and 10),
 error_code text,
 error_message text,
 metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object'),
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,binding_id,request_fingerprint)
);
alter table public.integration_runs enable row level security;
revoke all on table public.integration_runs from anon, authenticated;
grant select on table public.integration_runs to authenticated;
create policy integration_runs_select_member on public.integration_runs for select to authenticated
 using (public.is_active_organization_member(organization_id));

create table public.integration_run_artifacts (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 run_id uuid not null references public.integration_runs(id) on delete restrict,
 artifact_kind text not null check (artifact_kind in ('request_metadata','response_metadata','raw_payload','import_batch','diagnostic')),
 import_batch_id uuid references public.import_batches(id),
 payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload)='object'),
 content_sha256 text,
 created_at timestamptz not null default now()
);
alter table public.integration_run_artifacts enable row level security;
revoke all on table public.integration_run_artifacts from anon, authenticated;
grant select on table public.integration_run_artifacts to authenticated;
create policy integration_run_artifacts_select_member on public.integration_run_artifacts for select to authenticated
 using (public.is_active_organization_member(organization_id));

create index integration_runs_org_status_created_idx on public.integration_runs(organization_id,status,created_at desc);
create index integration_runs_binding_idx on public.integration_runs(binding_id);
create index integration_run_artifacts_run_idx on public.integration_run_artifacts(run_id);
create index integration_run_artifacts_batch_idx on public.integration_run_artifacts(import_batch_id) where import_batch_id is not null;

create or replace function public.guard_integration_run_consistency()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare b_org uuid; b_adapter uuid; b_enabled boolean; a_status text; a_caps jsonb;
begin
 select organization_id,adapter_id,enabled into b_org,b_adapter,b_enabled from public.integration_source_bindings where id=new.binding_id;
 if b_org is null or b_org<>new.organization_id or b_adapter<>new.adapter_id or not b_enabled then
   raise exception 'invalid or disabled integration binding';
 end if;
 select status,capabilities into a_status,a_caps from public.integration_adapters where id=new.adapter_id;
 if a_status='disabled' or not (a_caps ? new.capability) then raise exception 'adapter capability unavailable'; end if;
 if new.status='running' and new.started_at is null then new.started_at:=now(); end if;
 if new.status in ('succeeded','failed','cancelled') and new.finished_at is null then new.finished_at:=now(); end if;
 if new.status='succeeded' and new.error_code is not null then raise exception 'successful run cannot have error_code'; end if;
 return new;
end $$;
revoke all on function public.guard_integration_run_consistency() from public,anon,authenticated;
create trigger trg_integration_run_consistency before insert or update on public.integration_runs
for each row execute function public.guard_integration_run_consistency();

create or replace function public.guard_integration_artifact_consistency()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare r_org uuid; b_org uuid;
begin
 select organization_id into r_org from public.integration_runs where id=new.run_id;
 if r_org is null or r_org<>new.organization_id then raise exception 'artifact organization mismatch'; end if;
 if new.import_batch_id is not null then
   select organization_id into b_org from public.import_batches where id=new.import_batch_id;
   if b_org is null or b_org<>new.organization_id then raise exception 'artifact batch organization mismatch'; end if;
 end if;
 return new;
end $$;
revoke all on function public.guard_integration_artifact_consistency() from public,anon,authenticated;
create trigger trg_integration_artifact_consistency before insert or update on public.integration_run_artifacts
for each row execute function public.guard_integration_artifact_consistency();

comment on table public.integration_runs is 'Auditable idempotent execution envelope for provider adapters. No credentials or access tokens.';
comment on table public.integration_run_artifacts is 'Non-secret execution evidence and lineage; raw provider payload may be recorded here only after adapter-side redaction.';
