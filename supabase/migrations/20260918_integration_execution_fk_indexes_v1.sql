-- Mirror of live migration 20260918214814 integration_execution_fk_indexes_v1 (already applied).
-- Repository reconciliation only; do not re-apply as new history.
create index integration_runs_adapter_idx on public.integration_runs(adapter_id);
create index integration_runs_created_by_idx on public.integration_runs(created_by) where created_by is not null;
create index integration_run_artifacts_org_idx on public.integration_run_artifacts(organization_id);
