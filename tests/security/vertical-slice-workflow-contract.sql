-- POST-APPLY CONTRACT — vertical slice workflow + private storage.
-- Run only after 20260918_vertical_slice_domain_workflow_v0.sql and
-- 20260918_document_storage_rls_v0.sql have been applied to the target DB.

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='create_proposal_from_simulation' and p.prosecdef=false
  ) then raise exception 'create_proposal_from_simulation must exist as SECURITY INVOKER'; end if;

  if has_function_privilege('anon', 'public.create_proposal_from_simulation(uuid)', 'EXECUTE') then
    raise exception 'anon must not execute create_proposal_from_simulation';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='prepare_proposal_documents' and p.prosecdef=false
  ) then raise exception 'prepare_proposal_documents must exist as SECURITY INVOKER'; end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='send_proposal_to_digitization' and p.prosecdef=false
  ) then raise exception 'send_proposal_to_digitization must exist as SECURITY INVOKER'; end if;

  if has_function_privilege('anon', 'public.prepare_proposal_documents(uuid)', 'EXECUTE') then
    raise exception 'anon must not execute prepare_proposal_documents';
  end if;
  if has_function_privilege('anon', 'public.send_proposal_to_digitization(uuid)', 'EXECUTE') then
    raise exception 'anon must not execute send_proposal_to_digitization';
  end if;
  if not has_function_privilege('authenticated', 'public.prepare_proposal_documents(uuid)', 'EXECUTE') then
    raise exception 'authenticated must execute prepare_proposal_documents';
  end if;
  if not has_function_privilege('authenticated', 'public.send_proposal_to_digitization(uuid)', 'EXECUTE') then
    raise exception 'authenticated must execute send_proposal_to_digitization';
  end if;

  if not exists (
    select 1 from pg_indexes where schemaname='public' and tablename='proposals_v2'
      and indexname='proposals_v2_org_simulation_unique'
  ) then raise exception 'one-proposal-per-simulation unique index missing'; end if;

  if not exists (
    select 1 from storage.buckets where id='corban-documents' and public=false
  ) then raise exception 'private corban-documents bucket missing'; end if;

  if not exists (
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname='corban_documents_select_tenant_member' and roles @> array['authenticated']::name[]
  ) then raise exception 'tenant storage SELECT policy missing'; end if;

  if not exists (
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname='corban_documents_insert_tenant_member' and roles @> array['authenticated']::name[]
  ) then raise exception 'tenant storage INSERT policy missing'; end if;

  if exists (
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname like 'corban_documents_%' and cmd in ('UPDATE','DELETE','ALL')
  ) then raise exception 'authenticated document evidence must not have UPDATE/DELETE storage policy'; end if;
end $$;
